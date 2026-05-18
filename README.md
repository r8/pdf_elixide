# PdfElixide

[![Elixir CI](https://github.com/r8/pdf_elixide/actions/workflows/elixir.yml/badge.svg)](https://github.com/r8/pdf_elixide/actions/workflows/elixir.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/pdf_elixide.svg?style=flat-square)](https://hex.pm/packages/pdf_elixide)
[![Hex.pm](https://img.shields.io/hexpm/dt/pdf_elixide.svg?style=flat-square)](https://hex.pm/packages/pdf_elixide)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)

Elixir bindings for [pdf_oxide](https://crates.io/crates/pdf_oxide), a high-performance PDF library written in Rust. Built on top of [Rustler](https://github.com/rusterlium/rustler).

## Features

- Open PDF documents from a file path or an in-memory binary
- Query the PDF specification version
- Get the page count
- Extract text from a specific page

## Requirements

- Elixir `~> 1.19`
- Erlang/OTP compatible with the above
- A working [Rust toolchain](https://www.rust-lang.org/tools/install) (stable) for compiling the NIF

## Installation

Add `pdf_elixide` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pdf_elixide, "~> 0.1.0"}
  ]
end
```

Then fetch and compile:

```sh
mix deps.get
mix compile
```

The Rust NIF is compiled automatically by Rustler on first build.

## Usage

```elixir
# Open from a file path
{:ok, doc} = PdfElixide.open("path/to/file.pdf")

# Or from an in-memory binary
{:ok, bytes} = File.read("path/to/file.pdf")
{:ok, doc}   = PdfElixide.from_binary(bytes)

# Inspect the document
{:ok, {1, 4}} = PdfElixide.version(doc)
{:ok, 3}      = PdfElixide.page_count(doc)

# Extract text from a single page (zero-based index)
{:ok, text} = PdfElixide.extract_text(doc, 0)
```

Every function ships with a bang variant that returns the value directly and raises on error:

```elixir
doc   = PdfElixide.open!("path/to/file.pdf")
pages = PdfElixide.page_count!(doc)
text  = PdfElixide.extract_text!(doc, 0)
```

## Documentation

Full API documentation is published on [HexDocs](https://hexdocs.pm/pdf_elixide).

## License

Released under the [MIT License](LICENSE).
