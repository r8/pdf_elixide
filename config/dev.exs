import Config

config :rustler_precompiled, :force_build, pdf_elixide: true

config :git_hooks,
  auto_install: true,
  verbose: true,
  hooks: [
    pre_commit: [
      tasks: [
        {:cmd, "mix format"},
        {:cmd, "mix credo --strict"},
        {:cmd, "cargo +nightly fmt"},
        {:cmd, "cargo clippy --offline --all-targets -- -D warnings"},
        {:file, "priv/hooks/stage-cargo-lock.sh"}
      ]
    ],
    pre_push: [
      tasks: [
        {:cmd, "mix format --check-formatted"},
        {:cmd, "cargo +nightly fmt --check"},
        {:cmd, "mix credo --strict"},
        {:cmd, "mix test --color"},
        {:cmd, "mix dialyzer --quiet-with-result"}
      ]
    ]
  ]

config :git_ops,
  mix_project: Mix.Project.get!(),
  changelog_file: "CHANGELOG.md",
  types: [tidbit: [hidden?: true], important: [header: "Important Changes"]],
  github_handle_lookup?: true,
  repository_url: "https://github.com/r8/pdf_elixide",
  version_tag_prefix: "v",
  manage_mix_version?: true,
  manage_readme_version: true,
  managed_files: [
    {"native/pdf_elixide_nif/Cargo.toml",
     fn v -> "name = \"pdf_elixide_nif\"\nversion = \"#{v}\"" end,
     fn v -> "name = \"pdf_elixide_nif\"\nversion = \"#{v}\"" end}
  ]
