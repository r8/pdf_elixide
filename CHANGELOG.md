# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [v0.8.0](https://github.com/r8/pdf_elixide/compare/v0.7.0...v0.8.0) (2026-07-25)




### Features:

* add options to the extractors by [@r8](https://github.com/r8)

* upgrade pdf_oxide to 0.3.75 by [@r8](https://github.com/r8)

* add to_markdown, to_html, and to_text for Table by [@r8](https://github.com/r8)

* add HTML conversion with to_html for Document and Page by [@r8](https://github.com/r8)

* add Markdown conversion with to_markdown for Document and Page by [@r8](https://github.com/r8)

* add cell, row, and Enumerable accessors to Table by [@r8](https://github.com/r8)

* add close/1 and closed?/1 functions for resource management by [@r8](https://github.com/r8)

* introduce color structs for CMYK, Gray, RGB, and Unknown by [@r8](https://github.com/r8)

* add annotations extraction by [@r8](https://github.com/r8)

* add metadata, permissions, and page labels extraction by [@r8](https://github.com/r8)

* add fonts extraction by [@r8](https://github.com/r8)

* add outline extraction by [@r8](https://github.com/r8)

* add XFA detection with Document.has_xfa?/1 by [@r8](https://github.com/r8)

### Bug Fixes:

* re-raise non-ErlangError exceptions from Wrap.call/1 by [@r8](https://github.com/r8)

* sort extracted fonts by resource name for deterministic order by [@r8](https://github.com/r8)

## [v0.7.0](https://github.com/r8/pdf_elixide/compare/v0.6.0...v0.7.0) (2026-07-23)




### Features:

* add image extraction by [@r8](https://github.com/r8)

* add path extraction by [@r8](https://github.com/r8)

* add structured PdfElixide.Error with matchable reason atoms by [@r8](https://github.com/r8)

### Bug Fixes:

* force NIF build when PDF_ELIXIDE_BUILD is set by [@r8](https://github.com/r8)

## [v0.6.0](https://github.com/r8/pdf_elixide/compare/v0.5.0...v0.6.0) (2026-07-20)




### Features:

* add table extraction by [@r8](https://github.com/r8)

* add span extraction by [@r8](https://github.com/r8)

* add char extraction by [@r8](https://github.com/r8)

## [v0.5.0](https://github.com/r8/pdf_elixide/compare/v0.4.0...v0.5.0) (2026-07-14)




### Features:

* add text line extraction with nested words by [@r8](https://github.com/r8)

* add word extraction with bounding boxes by [@r8](https://github.com/r8)

* add Document.text/1 for whole-document text extraction by [@r8](https://github.com/r8)

* add text getter to Page by [@r8](https://github.com/r8)

* implement Enumerable protocol for Document by [@r8](https://github.com/r8)

* add width and height getters to Page by [@r8](https://github.com/r8)

* add Page module by [@r8](https://github.com/r8)

## [v0.4.0](https://github.com/r8/pdf_elixide/compare/v0.3.1...v0.4.0) (2026-05-25)




### Features:

* add `has_structure_tree?` check to Document by [@r8](https://github.com/r8)

* add password authentication for opening encrypted PDFs by [@r8](https://github.com/r8)

* add PDF encryption handling and authentication functions by [@r8](https://github.com/r8)

## [v0.3.1](https://github.com/r8/pdf_elixide/compare/v0.3.0...v0.3.1) (2026-05-20)




### Bug Fixes:

* relax elixir requirements by [@r8](https://github.com/r8)

* tune rustler dependencies by [@r8](https://github.com/r8)

## [v0.3.0](https://github.com/r8/pdf_elixide/compare/v0.2.0...v0.3.0) (2026-05-20)




### Features:

* implement save to file with options by [@r8](https://github.com/r8)

* implement setting form field by [@r8](https://github.com/r8)

* add editor module by [@r8](https://github.com/r8)

## [v0.2.0](https://github.com/r8/pdf_elixide/compare/v0.1.0...v0.2.0) (2026-05-19)




### Features:

* implement form fields extraction by [@r8](https://github.com/r8)

## [v0.1.0](https://github.com/r8/pdf_elixide/compare/v0.1.0...v0.1.0) (2026-05-18)




### Features:

* implement extract_text method by [@r8](https://github.com/r8)

* implement version method by [@r8](https://github.com/r8)

* implement page_count method by [@r8](https://github.com/r8)

* implement PDF loading by [@r8](https://github.com/r8)

### Bug Fixes:

* move git hooks configuration to dev config by [@r8](https://github.com/r8)
