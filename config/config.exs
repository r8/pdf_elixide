import Config

# Keys `PdfElixide.Logging` attaches to every record it forwards. Declared here
# so this project's own runs render them; a consuming application opts in by
# naming them in its own Logger config.
config :logger, :default_formatter, metadata: [:pdf_elixide, :pdf_source]

if config_env() == :dev do
  import_config "dev.exs"
end

if config_env() == :test do
  import_config "test.exs"
end
