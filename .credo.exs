# Credo gates both the pre-commit hook and CI, so the one check this project
# opts into beyond Credo's defaults is written down here rather than left to a
# dependency's default set.
#
# `extra:` merges onto the default enabled checks — it does not vendor them, so
# this file adds a check without freezing what Credo enables by default. That
# trade is deliberate: pinning the whole set would mean carrying the ~200-line
# `mix credo gen.config` dump and re-reviewing it on every Credo upgrade.
%{
  configs: [
    %{
      name: "default",
      checks: %{
        extra: [
          # Ships disabled and tagged `:controversial` upstream, so `--strict`
          # would not otherwise catch it. Enabled because a multi-alias is
          # invisible to `grep PdfElixide.Color.RGB`, and because every module
          # in `lib/` already aliases one per line — this keeps that uniform
          # rather than leaving it to whoever writes the next alias.
          {Credo.Check.Readability.MultiAlias, []}
        ]
      }
    }
  ]
}
