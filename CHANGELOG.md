# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-07-05

### Fixed

- 32-bit targets now compile. `u64` span offsets are cast to `usize` at
  slice-indexing and loop-index sites that failed to build where `usize`
  is 32-bit (e.g. `wasm32-wasi`). No API or behavior change on 64-bit
  targets.

## [0.1.0] - 2026-07-03

Initial release. RFC 8259 JSON (and JSONC) parser, encoder, typed codec,
lossless document model, incremental event reader, and tooling.

### Added

- RFC 8259 parser: single-pass recursive descent into an arena-allocated
  `Value` tree, zero-copy strings where no escapes occur, and a
  configurable nesting-depth cap (`ParseOptions.max_depth`, default 128).
- JSONC dialect: `//` and `/* */` comments plus trailing commas via
  `ParseOptions.dialect = .jsonc`; encoding always emits plain JSON.
- Number policy: `ParseOptions.number_mode = .typed` (default, i128/f64) or
  `.raw` to preserve the verbatim numeric lexeme (`Value.number_raw`) for
  arbitrary-precision round-tripping.
- Typed decoding: `parseInto` / `parseIntoReader` / `decode` via comptime
  reflection over structs, slices, arrays, optionals, enums, and tagged
  unions, with `json_rename` / `json_flatten` / `json_skip` / `json_tag`
  annotations and `fromJson` / `toJson` hooks.
- Single-pass typed decode: `parseInto` streams tokens straight into the
  target type (no intermediate `Value` tree) for types without `Value`
  fields, `fromJson` hooks, or tagged unions; on any error it re-decodes
  through the tree path so diagnostics are identical either way.
- Encoding: compact `encode`, indented `encodePretty`, and
  annotation-aware `encodeTyped` with shortest-round-trip float output.
- Lossless document model: `Document.parse` keeps source bytes; emit is
  byte-identical when unmodified and minimal-diff after `set` /
  `setLiteral` / `remove` / comment edits.
- Incremental event reader: `EventReader` pull-parses from fed byte chunks
  or a `std.Io.Reader` with bounded memory, returning `error.NeedMoreInput`
  when more bytes are needed. `materialize` builds a `Value` subtree at the
  current position, and `ValueStream` iterates top-level array elements or
  whitespace-separated documents (NDJSON). Token-length and depth bounds
  (`max_token_len`, `max_depth`) guard untrusted input.
- Buffered reader input: `parseReader` / `parseIntoReader` drain any
  `std.Io.Reader`; a standalone `Tokenizer` exposes lexer-level tokens for
  tooling.
- Byte-precise source spans (opt-in via `ParseOptions.spans`): each span is
  a `{ start, end }` pair of `u64` byte offsets addressing inputs of any
  size, keyed by dotted path. Derive 1-indexed line/column on demand with
  `Span.lineCol(src)`; `Diagnostic.render` takes the source bytes to derive
  location.
- Large inputs: all internal parser/tokenizer offsets and stored spans are
  `u64`, so plain `parse` / `parseInto`, streaming (`EventReader` /
  `ValueStream`), the spans map, and the document model handle inputs of any
  size with no 4 GiB cap.
- Multi-error diagnostics: one pass collects up to 100 errors with
  recovery, rendered one-line (`render`) or rustc-style via `Diagnostic.renderRich`
  with "did you mean" suggestions.
- Conformance: the full JSONTestSuite corpus is vendored and enforced in
  `zig build test` (95 accept / 188 reject / 35 pinned policy decisions),
  alongside round-trip and lossless-emit checks; the event reader is
  cross-checked against the tree parser over the same corpus.
- Tooling: random-input fuzzer (`zig build fuzz`), microbenchmarks
  (`zig build bench`), generated reference docs (`zig build docs`), and
  runnable examples (`basic`, `typed`, `edit`, `spans`, `stream`).

[Unreleased]: https://github.com/sakakibara/json-zig/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/sakakibara/json-zig/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/sakakibara/json-zig/releases/tag/v0.1.0
