// Page lookups shared by the document, the editor and the renderer.

use pdf_oxide::{
    error::{Error, Result},
    object::Object,
    PdfDocument,
};
use rustler::NifResult;

use crate::{
    atoms,
    error::{tagged_err, to_nif_err},
};

// Upstream reports a bad index as a generic `InvalidPdf`; this gives
// `:out_of_range`.
pub(crate) fn ensure_page_in_range(doc: &PdfDocument, page_index: usize) -> NifResult<()> {
    let count = doc.page_count().map_err(to_nif_err)?;
    if page_index >= count {
        return Err(tagged_err(
            atoms::out_of_range(),
            format!("Page index {page_index} out of range (document has {count} pages)"),
        ));
    }
    Ok(())
}

// Read the merged page dictionary and resolve the box and its elements so
// inherited and indirect spellings behave like `/MediaBox`; `null` is absent.
pub(crate) fn read_crop_box(doc: &PdfDocument, page_index: usize) -> Result<Option<[f32; 4]>> {
    let page = doc.get_page(page_index)?;
    let dict = page
        .as_dict()
        .ok_or_else(|| Error::InvalidPdf("Page is not a dictionary".to_string()))?;

    let Some(raw) = dict.get("CropBox") else {
        return Ok(None);
    };
    let resolved = doc.resolve_object(raw)?;
    if matches!(resolved, Object::Null) {
        return Ok(None);
    }
    let elements = resolved
        .as_array()
        .ok_or_else(|| Error::InvalidPdf("CropBox is not an array".to_string()))?;
    if elements.len() < 4 {
        return Err(Error::InvalidPdf(
            "CropBox must have at least 4 elements".to_string(),
        ));
    }

    let mut corners = [0.0f32; 4];
    for (corner, element) in corners.iter_mut().zip(elements) {
        *corner = match doc.resolve_object(element)? {
            Object::Integer(v) => v as f32,
            Object::Real(v) => v as f32,
            _ => 0.0,
        };
    }

    Ok(Some(corners))
}
