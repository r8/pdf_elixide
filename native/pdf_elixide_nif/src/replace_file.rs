use std::{
    fs::{self, DirBuilder, OpenOptions},
    io,
    path::{Path, PathBuf},
    process,
    sync::atomic::{AtomicU64, Ordering},
};

use pdf_oxide::Error as PdfError;
use rustler::NifResult;

use crate::error::to_nif_err;

// Stage regular-file writes so a failed writer cannot truncate the target.
pub fn replace_file<T>(path: &Path, write: impl FnOnce(&Path) -> NifResult<T>) -> NifResult<T> {
    staged_write(path, write, |e| to_nif_err(PdfError::Io(e)))
}

fn staged_write<T, E>(
    path: &Path,
    write: impl FnOnce(&Path) -> Result<T, E>,
    io_err: impl Fn(io::Error) -> E,
) -> Result<T, E> {
    // Renaming would replace a special node instead of writing to it.
    if fs::metadata(path).is_ok_and(|meta| !meta.is_file() && !meta.is_dir()) {
        return write(path);
    }

    let Some(target) = resolve(path).map_err(&io_err)? else {
        return write(path);
    };
    let staged = Staged::create(&target).map_err(&io_err)?;
    let value = write(&staged.file)?;

    staged.persist(&target).map_err(io_err)?;
    Ok(value)
}

// Bounds the manual traversal, which a link cycle would otherwise never end.
const MAX_LINKS: usize = 40;

// Descriptor links describe open files, not replacement destinations.
const DESCRIPTOR_DIRS: [&str; 2] = ["/proc", "/dev/fd"];

// Follow even dangling symlinks; return None for descriptors.
fn resolve(path: &Path) -> io::Result<Option<PathBuf>> {
    let mut path = path.to_path_buf();
    let mut followed = 0;

    loop {
        if DESCRIPTOR_DIRS.iter().any(|dir| path.starts_with(dir)) {
            return Ok(None);
        }

        let is_link = fs::symlink_metadata(&path).is_ok_and(|meta| meta.file_type().is_symlink());
        if !is_link {
            return Ok(Some(path));
        }
        if followed == MAX_LINKS {
            return Err(io::Error::other(format!(
                "{} goes through too many symbolic links",
                path.display()
            )));
        }

        let link = fs::read_link(&path)?;
        path = match path.parent() {
            Some(dir) if link.is_relative() => dir.join(link),
            _ => link,
        };
        followed += 1;
    }
}

static NEXT: AtomicU64 = AtomicU64::new(0);

// A private directory protects the path the writer reopens.
// Drop cleans up on errors and unwinding panics.
struct Staged {
    dir: PathBuf,
    file: PathBuf,
    persisted: bool,
}

impl Staged {
    fn create(target: &Path) -> io::Result<Self> {
        if target.file_name().is_none() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{} does not name a file", target.display()),
            ));
        }

        let parent = match target.parent() {
            Some(dir) if !dir.as_os_str().is_empty() => dir,
            _ => Path::new("."),
        };

        loop {
            let dir = parent.join(format!(
                ".pdf_elixide.{}.{}",
                process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));

            match private_dir().create(&dir) {
                Ok(()) => {
                    return Ok(Self {
                        file: dir.join("staged"),
                        dir,
                        persisted: false,
                    });
                }
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e),
            }
        }
    }

    fn persist(mut self, target: &Path) -> io::Result<()> {
        OpenOptions::new()
            .write(true)
            .open(&self.file)?
            .sync_all()?;
        keep_permissions(&self.file, target)?;
        fs::rename(&self.file, target)?;

        self.persisted = true;
        Ok(())
    }
}

impl Drop for Staged {
    fn drop(&mut self) {
        if !self.persisted {
            let _ = fs::remove_file(&self.file);
        }
        let _ = fs::remove_dir(&self.dir);
    }
}

#[cfg(unix)]
fn private_dir() -> DirBuilder {
    use std::os::unix::fs::DirBuilderExt;

    let mut builder = DirBuilder::new();
    builder.mode(0o700);
    builder
}

#[cfg(not(unix))]
fn private_dir() -> DirBuilder {
    DirBuilder::new()
}

#[cfg(unix)]
fn keep_permissions(staged: &Path, target: &Path) -> io::Result<()> {
    match fs::metadata(target) {
        Ok(meta) if meta.is_file() => fs::set_permissions(staged, meta.permissions()),
        _ => Ok(()),
    }
}

// A read-only Windows target already refuses rename.
#[cfg(not(unix))]
fn keep_permissions(_staged: &Path, _target: &Path) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::panic::{self, AssertUnwindSafe};

    use super::*;

    fn scratch(label: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("pdf_elixide_replace_{label}_{}", process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir(&dir).unwrap();
        dir
    }

    fn entries(dir: &Path) -> Vec<PathBuf> {
        let mut entries: Vec<PathBuf> = fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect();
        entries.sort();
        entries
    }

    #[test]
    fn a_panicking_writer_leaves_the_target_and_no_staged_file() {
        let dir = scratch("panic");
        let target = dir.join("out.pdf");
        fs::write(&target, b"original").unwrap();

        let unwound = panic::catch_unwind(AssertUnwindSafe(|| {
            staged_write(
                &target,
                |staged| -> Result<(), io::Error> {
                    fs::write(staged, b"partial")?;
                    panic!("writer failed mid-write");
                },
                |e| e,
            )
        }));

        let left = entries(&dir);
        let original = fs::read(&target).unwrap();
        fs::remove_dir_all(&dir).unwrap();

        assert!(unwound.is_err());
        assert_eq!(original, b"original");
        assert_eq!(left, vec![target]);
    }

    #[cfg(unix)]
    #[test]
    fn writes_inside_a_directory_only_this_user_can_enter() {
        use std::os::unix::fs::PermissionsExt;

        let dir = scratch("private");
        let target = dir.join("out.pdf");

        let mode = staged_write(
            &target,
            |staged| {
                fs::write(staged, b"new")?;
                let parent = staged.parent().unwrap();
                fs::metadata(parent).map(|meta| meta.permissions().mode() & 0o777)
            },
            |e| e,
        )
        .unwrap();

        let left = entries(&dir);
        let written = fs::read(&target).unwrap();
        fs::remove_dir_all(&dir).unwrap();

        assert_eq!(mode, 0o700);
        assert_eq!(written, b"new");
        assert_eq!(left, vec![target]);
    }

    #[cfg(unix)]
    #[test]
    fn follows_a_relative_link_to_a_file_that_does_not_exist_yet() {
        let dir = scratch("dangling");
        let link = dir.join("link.pdf");
        std::os::unix::fs::symlink("sub/../intended.pdf", &link).unwrap();
        fs::create_dir(dir.join("sub")).unwrap();

        let resolved = resolve(&link).unwrap();
        fs::remove_dir_all(&dir).unwrap();

        assert_eq!(resolved, Some(dir.join("sub/../intended.pdf")));
    }

    #[cfg(unix)]
    #[test]
    fn writes_to_a_special_file_in_place_rather_than_replacing_it() {
        use std::os::unix::{fs::FileTypeExt, net::UnixListener};

        let dir = scratch("special");
        let socket = dir.join("out.pdf");
        let _listener = UnixListener::bind(&socket).unwrap();

        let written = staged_write(&socket, |path| fs::write(path, b"new"), |e| e);
        let still_a_socket = fs::symlink_metadata(&socket)
            .unwrap()
            .file_type()
            .is_socket();
        let left = entries(&dir);
        fs::remove_dir_all(&dir).unwrap();

        assert!(written.is_err());
        assert!(still_a_socket);
        assert_eq!(left, vec![socket]);
    }

    #[cfg(unix)]
    #[test]
    fn treats_a_standard_stream_as_a_descriptor() {
        assert_eq!(resolve(Path::new("/dev/stdout")).unwrap(), None);
    }

    #[cfg(unix)]
    #[test]
    fn writes_an_unlinked_file_through_its_descriptor() {
        use std::{
            io::{Read, Seek},
            os::fd::AsRawFd,
        };

        let dir = scratch("descriptor");
        let path = dir.join("open.pdf");
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        fs::remove_file(&path).unwrap();

        let by_descriptor = PathBuf::from(format!("/dev/fd/{}", file.as_raw_fd()));
        let written = staged_write(&by_descriptor, |path| fs::write(path, b"new"), |e| e);

        let mut contents = Vec::new();
        file.rewind().unwrap();
        file.read_to_end(&mut contents).unwrap();
        let left = entries(&dir);
        fs::remove_dir_all(&dir).unwrap();

        written.unwrap();
        assert_eq!(contents, b"new");
        assert!(left.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn follows_exactly_as_many_links_as_allowed() {
        let dir = scratch("chain");
        let target = dir.join("target.pdf");
        let link = |n: usize| dir.join(format!("link{n}.pdf"));
        for n in 1..=MAX_LINKS + 1 {
            let next = if n == 1 { target.clone() } else { link(n - 1) };
            std::os::unix::fs::symlink(next, link(n)).unwrap();
        }

        let at_limit = resolve(&link(MAX_LINKS)).unwrap();
        let past_limit = resolve(&link(MAX_LINKS + 1));
        fs::remove_dir_all(&dir).unwrap();

        assert_eq!(at_limit, Some(target));
        assert!(past_limit.is_err());
    }

    #[cfg(unix)]
    #[test]
    fn refuses_a_link_cycle() {
        let dir = scratch("cycle");
        let link = dir.join("loop.pdf");
        std::os::unix::fs::symlink("loop.pdf", &link).unwrap();

        let resolved = resolve(&link);
        fs::remove_dir_all(&dir).unwrap();

        assert!(resolved.is_err());
    }
}
