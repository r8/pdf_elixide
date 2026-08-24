# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [v0.15.0](https://github.com/r8/pdf_elixide/compare/v0.14.0...v0.15.0) (2026-08-24)




### Features:

* add signature certificate parsing by [@r8](https://github.com/r8)

* verify adbe.pkcs7.sha1 signatures by [@r8](https://github.com/r8)

* validate timestamps structurally, include signed data in token scope by [@r8](https://github.com/r8)

* improve signatures with B-LTA, parsed signing times, and signer certs by [@r8](https://github.com/r8)

* identify signed and unsigned signature fields by [@r8](https://github.com/r8)

* report PAdES levels, timestamps, and security store data by [@r8](https://github.com/r8)

* verify PDF signatures and expose signer certificates by [@r8](https://github.com/r8)

* capture upstream log output so a silently degraded page says why by [@r8](https://github.com/r8)

### Bug Fixes:

* escape document-controlled font names in inspect output by [@r8](https://github.com/r8)

## [v0.14.0](https://github.com/r8/pdf_elixide/compare/v0.13.0...v0.14.0) (2026-08-20)




### Features:

* add digital signature reading by [@r8](https://github.com/r8)

* add form and annotation flattening by [@r8](https://github.com/r8)

## [v0.13.0](https://github.com/r8/pdf_elixide/compare/v0.12.0...v0.13.0) (2026-08-10)




### Features:

* classify form fields from their flags by [@r8](https://github.com/r8)

* return the editor from every form write so filling a form is one pipeline by [@r8](https://github.com/r8)

* represent form fields as per-kind structs by [@r8](https://github.com/r8)

* add Form.field/2 and value/2 and key form fields by full name by [@r8](https://github.com/r8)

## [v0.12.0](https://github.com/r8/pdf_elixide/compare/v0.11.1...v0.12.0) (2026-08-05)




### Features:

* add Editor version, page count and modified getters by [@r8](https://github.com/r8)

* add text search by [@r8](https://github.com/r8)

## [v0.11.1](https://github.com/r8/pdf_elixide/compare/v0.11.0...v0.11.1) (2026-08-01)




### Bug Fixes:

* accept any path the OS does, so a byte filename no longer raises by [@r8](https://github.com/r8)

## [v0.11.0](https://github.com/r8/pdf_elixide/compare/v0.10.0...v0.11.0) (2026-07-30)




### Features:

* add rects and lines extractors by [@r8](https://github.com/r8)

* add layers and inks extractors by [@r8](https://github.com/r8)

* add page text layer detection by [@r8](https://github.com/r8)

* add page media box extraction by [@r8](https://github.com/r8)

* add page rotation extraction by [@r8](https://github.com/r8)

## [v0.10.0](https://github.com/r8/pdf_elixide/compare/v0.9.0...v0.10.0) (2026-07-28)




### Features:

* read documents through a shared lock so one handle serves concurrent reads by [@r8](https://github.com/r8)

### Bug Fixes:

* report the index and count when page/2 rejects an out-of-range page by [@r8](https://github.com/r8)

* unify bad option error handling by [@r8](https://github.com/r8)

* decode the open-option password as bytes so a non-UTF-8 password works by [@r8](https://github.com/r8)

* cap outline conversion depth so a hostile bookmark tree can't abort the VM by [@r8](https://github.com/r8)

## [v0.9.0](https://github.com/r8/pdf_elixide/compare/v0.8.0...v0.9.0) (2026-07-26)




### Features:

* add strict has_structure_tree/1 and has_xfa/1 so a swallowed error is reachable by [@r8](https://github.com/r8)

* add on_page_error to fail whole-document text on an unextractable page by [@r8](https://github.com/r8)

### Bug Fixes:

* return the version and page count from the open NIF so no handle can leak by [@r8](https://github.com/r8)

* match NIF success payloads loosely so a shape change can't raise CaseClauseError by [@r8](https://github.com/r8)

* read a single page label through a range-checked NIF by [@r8](https://github.com/r8)

* decode tables from a borrow instead of cloning for the resource by [@r8](https://github.com/r8)

* return JPEG-stored image bytes without cloning the stored blob by [@r8](https://github.com/r8)

* return an error instead of panicking when a binary allocation fails by [@r8](https://github.com/r8)

* decode Info strings as PDFDocEncoding, uniformly across all fields by [@r8](https://github.com/r8)

* cache page_count on the Document struct at open by [@r8](https://github.com/r8)

* schedule lock-taking document NIFs on dirty CPU schedulers by [@r8](https://github.com/r8)

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
