# json

A complete JSON + JSONC implementation for Zig.

- **Full conformance** - passes every fixture of [JSONTestSuite](https://github.com/nst/JSONTestSuite): all 95 `y_` files parse, all 188 `n_` files are rejected, and all 35 implementation-defined `i_` files follow an explicit, documented policy table. The corpus is vendored and runs in `zig build test`.
- **Typed decoding** - `parseInto(Config, arena, src, .{})` deserializes straight into your Zig struct via comptime reflection, in a single streaming pass with no intermediate value tree. No codegen.
- **Lossless document model** - edit a JSON or JSONC file in place; comments, formatting, ordering preserved. Unmodified documents emit byte-identical; edits produce minimal diffs.
- **Byte-precise spans** - every value (top-level or deeply nested) carries an exact `u64` byte range; 1-indexed line/col are derived on demand via `Span.lineCol`. No input-size cap.
- **JSONC dialect** - `//` and `/* */` comments plus trailing commas, behind a single option. Encoding always emits plain JSON.
- **Multi-error diagnostics** - one pass collects every parse error (up to 100), with rustc-style rendering: source excerpt, caret underline, "did you mean" suggestions.
- **Streaming / incremental** - parse from any `std.Io.Reader`; or use `EventReader` / `ValueStream` for bounded-memory SAX-style walks and NDJSON record iteration. A separate token-stream API yields lex events for tooling.
- **Fast** - single-pass recursive-descent, arena-allocated, zero-copy strings where possible, SIMD string scanning. Run `zig build bench` to measure on your hardware.
- **Portable** - builds on every target Zig supports (cross-compiled in CI). No allocator surprises, no global state.
- **No dependencies** - pure Zig, libc-free.

```zig
const json = @import("json");

const Config = struct {
    name: []const u8,
    port: u16 = 8080,
    server: struct {
        host: []const u8,
        tls: bool = false,
    },
};

const cfg = try json.parseInto(Config, arena, src, .{});
```

## Install

Requires Zig 0.16.0 or newer.

```sh
zig fetch --save git+https://github.com/sakakibara/json-zig
```

In `build.zig`:

```zig
const json = b.dependency("json", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("json", json.module("json"));
```

## Quickstart

### Dynamic parse

```zig
const std = @import("std");
const json = @import("json");

var arena_state = std.heap.ArenaAllocator.init(gpa);
defer arena_state.deinit();
const arena = arena_state.allocator();

const v = try json.parse(arena,
    \\{"server": {"host": "localhost", "port": 8080}}
, .{});

const port = v.getT(i64, "server.port") orelse 8080;
```

Snippets below reuse this setup: `arena` is always the
`std.mem.Allocator` obtained from `arena_state.allocator()`.

`getT` walks dotted paths with `[N]` array indices (`users[0].name`) and
returns `null` on a missing path or type mismatch.

### Typed decoding

Decode straight into a struct. Field defaults are honored; optionals become
`null` when absent; unknown JSON keys raise `error.UnknownField` (opt out
with `.ignore_unknown_fields = true`).

```zig
const Config = struct {
    name: []const u8,
    port: u16 = 8080,
    nick: ?[]const u8 = null,
    tags: []const []const u8,
    server: struct {
        host: []const u8,
        tls: bool = false,
    },
};

const cfg = try json.parseInto(Config, arena, src, .{});
```

Supported types: `bool`, all int/float widths (overflow-checked),
`[]const u8`, slices, fixed-size arrays, optionals, nested structs, enums
(string name or integer tag), `union(enum)` (tagged-union with the
`json_tag` annotation -- see below). Embed a raw `json.Value` to keep
dynamic substructures.

### Annotation-driven decode and encode

Decode supports the following `pub const` annotations on the target struct:

```zig
const Server = struct {
    pub const json_rename = .{ .listen_addr = "listen-addr" };
    pub const json_flatten = .{"common"};
    pub const json_skip = .{"runtime"};

    listen_addr: []const u8,
    common: CommonConfig, // sub-fields decode from the parent object
    runtime: u32 = 0,     // excluded from decode/encode
};
```

For custom (de)serialization of a type, provide either or both of these
hooks on the type:

```zig
pub fn fromJson(arena: Allocator, value: Value, options: ParseOptions) DecodeError!Self;
pub fn toJson(self: Self, arena: Allocator) Allocator.Error!Value;
```

Tagged unions decode/encode by a JSON discriminator member:

```zig
const Plugin = union(enum) {
    pub const json_tag = "kind";

    http: HttpConfig,
    grpc: GrpcConfig,
};
```

`"kind": "http"` in the object picks the `.http` variant; the remaining
members decode as `HttpConfig`. For variant-name overrides, use
`json_rename` on the union itself.

For symmetric encoding of typed values (consulting the same annotations),
use `json.encodeTyped(w, value, arena)`:

```zig
try json.encodeTyped(w, cfg, arena);
```

Annotations and hooks are read from `@TypeOf(value)`, so pass a value of
the annotated type itself. Bind an anonymous struct literal to the type
first (`const cfg: Config = .{ .name = "x" };`); an anonymous literal
has its own type, which carries no declarations.

The discriminator member is emitted first, with the payload's fields
inline in the same object, so the output decodes back via
`parseInto(T, ...)`. The plain `json.encode(w, value: Value)` still
applies for hand-built `Value` trees.

### Editing (lossless document model)

Read a JSON or JSONC file, edit values in place, emit byte-identical
output when unmodified or minimal-diff output when modified. Comments,
whitespace, member order, and trailing commas are all preserved.

```zig
var doc = try json.Document.parse(arena, src, .{ .dialect = .jsonc });

const port = doc.getT(u16, "server.port") orelse 8080;

// `set` is comptime-dispatched on the Zig type:
try doc.set("server.port", @as(u16, 9999));
try doc.set("server.tls", true);
try doc.set("server.host", "0.0.0.0");

// Escape hatch: splice in a literal JSON value string.
try doc.setLiteral("server.tags", "[\"alpha\", \"beta\"]");

try doc.remove("dev.unused");

// Comment editing (JSONC documents only):
try doc.addCommentBefore("server.port", "default port");
try doc.setTrailingComment("server.tls", "production only");

var aw: std.Io.Writer.Allocating = .init(gpa);
defer aw.deinit();
try doc.emit(&aw.writer);
```

`set` on an existing path replaces only the value's bytes; keys,
separators, comments, and surrounding formatting stay put. `set` on a
missing leaf appends a new member to its enclosing object, matching the
surrounding style (single-line objects get `, "k": v`; multi-line objects
get a comma, newline, and the indentation inferred from the last sibling).
Missing intermediate objects along the path are created too (`set("a.b.c",
v)` creates `a` and `a.b` as needed); array elements are still only ever
replaced, never created.

```jsonc
// Before:
{ "x": 1, "y": 2 }
// doc.setLiteral("x", "99") produces:
{ "x": 99, "y": 2 }
```

`Document.empty(arena, options)` bootstraps a document with no source
bytes at all -- the first `set` splices the root object and the whole
path in as one edit, for the "file doesn't exist yet" case. And
`setValueSegments` / `setSegments` / `removeSegments` take a path as
pre-split key segments instead of a dotted string, so a key containing a
literal `.` is addressed unambiguously:

```zig
var doc = try json.Document.empty(arena, .{});
try doc.setSegments(&.{ "host", "example.com" }, "1.2.3.4");
// {"host": {"example.com": "1.2.3.4"}} -- one literal key, not nested.
```

### Source spans

```zig
var spans: json.Spans = .empty;
const v = try json.parse(arena, src, .{ .spans = &spans });

if (v.locate(spans, "server.port")) |port| {
    // Spans store u64 byte offsets; line/col are derived on demand.
    const lc = port.span.lineCol(src);
    std.debug.print("port {d} at line {d} col {d}\n",
        .{ port.value.integer, lc.line, lc.col });
}
```

Array elements use `[N]` index segments, e.g. `users[0].name`. Spans carry
only `u64` byte offsets (no input-size cap); `Span.lineCol(src)` derives the
1-indexed line/column on demand.

### Streaming input

```zig
var stdin_buf: [4096]u8 = undefined;
var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
const v = try json.parseReader(arena, &stdin_reader.interface, .{});
```

(`io` is your `std.Io` instance, e.g. `init.io` from `main`.)

`parseReader` drains the reader fully before parsing: zero-copy strings
slice into the buffer, and a document is only valid once its final token
is seen, so a complete contiguous buffer is required anyway.

### Incremental event reader (bounded memory)

For processing large or streamed JSON without buffering the full document,
use `EventReader`. It yields one `Event` at a time; only a rolling window
of unconsumed bytes is kept in memory.

Two front-ends share the same core:

- **Reader-backed** -- wraps any `std.Io.Reader`; pulls data automatically
  on each `next()` call. No `feed` or `endInput` needed.

  ```zig
  var r: std.Io.Reader = .fixed(data);
  var er = json.EventReader.fromReader(gpa, &r, .{});
  defer er.deinit();
  while (try er.next()) |ev| { ... }
  ```

- **Feed-core** -- you supply bytes incrementally via `feed(bytes)` and
  signal the end of input with `endInput()`. When `next()` returns
  `error.NeedMoreInput`, feed more bytes and call `next()` again; once
  the chunks are exhausted, call `endInput()` (it cannot fail) so the
  reader can finish the final token instead of waiting for more data.

  ```zig
  var er = json.EventReader.init(gpa, .{});
  defer er.deinit();
  var chunk_idx: usize = 0;
  while (true) {
      const ev = er.next() catch |e| switch (e) {
          error.NeedMoreInput => {
              if (chunk_idx < chunks.len) {
                  try er.feed(chunks[chunk_idx]);
                  chunk_idx += 1;
              } else {
                  er.endInput();
              }
              continue;
          },
          else => return e,
      };
      if (ev == null) break;
      // use ev.?.kind, ev.?.span
  }
  ```

**Event kinds** (`ev.kind` is a tagged union):

| Variant | Payload |
| --- | --- |
| `object_begin` | - |
| `object_end` | - |
| `array_begin` | - |
| `array_end` | - |
| `object_key` | `[]const u8` -- decoded key string |
| `string` | `[]const u8` -- decoded string value |
| `number` | `[]const u8` -- raw lexeme (e.g. `"3.14"`) |
| `boolean` | `bool` |
| `null` | - |
| `end_of_input` | - |

A `number` event carries the raw lexeme; use `json.asInt` or `json.asFloat` to coerce it to `i128` or `f64`.

**Borrow contract**: `object_key`, `string`, and `number` payloads are
slices into the reader's internal buffer. They are valid only until the
next call to `next()` or `feed()` (either can move the buffer they borrow
from). Copy with `arena.dupe(u8, s)` if you need to keep
the value across calls.

**Bridging to `Value`**: call `er.materialize(arena)` immediately after a
value-starting event (`object_begin`, `array_begin`, or any scalar). It
consumes the reader until the value is complete and returns an
arena-allocated `Value` tree.

**`ValueStream`** wraps `EventReader` and yields one `Value` per record.
Reset a per-item arena between `next()` calls to bound total memory:

```zig
const ndjson = "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n";
var r: std.Io.Reader = .fixed(ndjson);
var vs = json.ValueStream.fromReader(gpa, &r, .{ .shape = .multi_document });
defer vs.deinit();

var item_arena: std.heap.ArenaAllocator = .init(gpa);
defer item_arena.deinit();
while (try vs.next(item_arena.allocator())) |record| {
    const n = record.getT(i64, "n").?;
    std.debug.print("n={d}\n", .{n});
    _ = item_arena.reset(.retain_capacity);
}
```

Three `StreamShape` values control how records are delimited:

| Shape | Meaning |
| --- | --- |
| `array_elements` | Top-level JSON array; each element is one record. |
| `multi_document` | Whitespace/newline-separated top-level values (NDJSON). |
| `auto` | Resolved from the first event: `array_begin` -> `array_elements`, otherwise `multi_document`. |

**Bounds**: `StreamOptions.max_depth` (default 128) caps nesting; any
container nested deeper returns `error.NestingTooDeep` immediately.
`max_token_len` (default 16 MiB) caps individual string and number tokens;
longer tokens return `error.TokenTooLong`. These keep both stack and buffer
usage bounded regardless of input size.

**Empty / whitespace-only input**: `EventReader` treats a stream with no
JSON value as valid and returns `end_of_input` with no error. This differs
from `json.parse`, which rejects empty input per RFC 8259. Callers that
require a single complete value should check that the first event is not
`end_of_input`.

**No multi-error recovery**: unlike `parse`, the streaming reader stops at
the first malformed token. The stream is unusable after a parse error.

### Token stream (for tooling)

For incremental syntax highlighters, format-preserving editors, or any
tool that wants to walk the source token-by-token without building a
Value tree:

```zig
var t: json.Tokenizer = .init(src, .jsonc);
while (t.next()) |tok| switch (tok.kind) {
    .string => highlight(.string, tok.span),
    .number => highlight(.number, tok.span),
    .literal_true, .literal_false, .literal_null => highlight(.literal, tok.span),
    .comment => highlight(.comment, tok.span),
    .object_begin, .object_end, .array_begin, .array_end => highlight(.punct, tok.span),
    else => {},
};
```

### Diagnostics on parse error

```zig
var errs: std.ArrayList(json.Diagnostic) = .empty;
defer errs.deinit(arena);
_ = json.parse(arena, src, .{ .errors = &errs }) catch {
    // Line/col are derived from the span, so `render` takes the source bytes.
    if (errs.items.len > 0) try errs.items[0].render(stderr_writer, src);
    return;
};
```

For rustc-style multi-line output with source-line excerpts, caret
underlines, and `did you mean` suggestions:

```zig
for (errs.items) |d| try d.renderRich(stderr_writer, src);
```

The parser collects every error in one pass when `errors` is set, up to
100 diagnostics per parse, resuming at the next `,` / `]` / `}` at the
same nesting level. Set it to `null` for single-error mode (bail on the
first error, no diagnostic captured).

Ownership: appended entries (and their messages and suggestions) live in
the parse arena. Deinit the list with that arena, as above, or just drop
it when the arena frees; the entries dangle once the arena is gone.

## Dialects

The default dialect is strict RFC 8259 JSON. Pass
`.{ .dialect = .jsonc }` to also accept:

- `//` line comments and `/* */` block comments
- trailing commas in arrays and objects

JSONC is a strict superset: every valid JSON document is also valid
JSONC. The dialect only affects parsing -- `encode`, `encodePretty`, and
`encodeTyped` always emit plain JSON, regardless of what the tree was
parsed from. Only the lossless `Document` model preserves JSONC syntax
through an edit cycle, and its comment-editing calls
(`addCommentBefore`, `setTrailingComment`) return
`error.CommentsNotSupported` on strict-JSON documents.

## Number policy

- A number without `.`, `e`, or `E` parses as `.integer` (i128). On i128
  overflow it falls back to `.float` (`f64`); parsing never fails on a
  grammatically valid number. Huge exponents resolve to +/-inf or 0.0,
  as RFC 8259 permits.
- `ParseOptions.number_mode = .raw` preserves every number as its verbatim
  source lexeme in `Value.number_raw` (no conversion), for
  arbitrary-precision round-tripping; `getT` still coerces on demand.
  Required for values beyond the i128 range (e.g. u128 values above i128
  max): in `.typed` mode such values overflow to `.float`, losing precision.
- Integer decode targets do not accept `.float` values: `1e2` parses as
  `.float` and stays one. Targets wider than i128 (e.g. bare `u128`) cannot
  receive literals above i128 max without `number_mode = .raw` -- such
  literals overflow to `.float` and fail with `error.TypeMismatch`.
- On encode, floats with |x| in [1e-6, 1e21) (and zero) use shortest
  round-trip decimal notation, with a `.0` suffix when integer-valued so
  they re-parse as `.float`; values outside that range use shortest
  scientific notation.
- NaN and +/-infinity have no JSON representation; encoding such a
  `.float` returns `error.UnrepresentableFloat`.

## API surface

### Functions

| Function | Purpose |
| --- | --- |
| `parse(arena, src, options)` | Dynamic parse to a `Value` tree. |
| `parseReader(arena, reader, options)` | Reader-input variant. |
| `parseInto(T, arena, src, options)` | Decode straight into an instance of `T`. |
| `parseIntoReader(T, arena, reader, options)` | Reader-input variant of `parseInto`. |
| `decode(T, arena, value, options)` | Decode an existing `Value` into `T`. |
| `encode(w, value)` | Emit compact JSON to a `*std.Io.Writer`. |
| `encodePretty(w, value, options)` | Emit indented JSON. |
| `encodeTyped(w, value, arena)` | Encode a typed value, honoring annotations and hooks. |
| `Document.parse(arena, src, options)` | Lossless parse for the document model. |
| `Document.empty(arena, options)` | Bootstrap a document with no source bytes. |
| `Tokenizer.init(src, dialect)` / `.next()` | Lexer-level token stream for tooling. |
| `EventReader.fromReader(gpa, reader, options)` | Incremental SAX reader backed by a `std.Io.Reader`. |
| `EventReader.init(gpa, options)` / `.feed(bytes)` / `.endInput()` | Feed-core variant; caller pushes bytes on demand. |
| `asInt(number_bytes)` | Coerce a streaming number event lexeme to `i128` (null on failure). |
| `asFloat(number_bytes)` | Coerce a streaming number event lexeme to `f64` (null on failure). |
| `ValueStream.fromReader(gpa, reader, options)` | Record iterator over a JSON array or NDJSON stream. |

### Types

`Value`, `ObjectMap`, `Span`, `Spans`, `Diagnostic`, `ParseOptions`,
`Dialect`, `NumberMode`, `PrettyOptions`, `Error`, `ReaderError`, `DecodeError`,
`EncodeError`, `DocumentError`, `Document`, `Token`, `TokenKind`,
`EventReader`, `Event`, `StreamOptions`, `StreamError`, `ValueStream`,
`StreamShape`.

Generated reference docs are published at
**https://sakakibara.github.io/json-zig/**.

Building locally (Zig's docs viewer is WASM-based and must be served over
HTTP, not opened as a `file://` URL):

```sh
zig build docs
cd zig-out/docs && python3 -m http.server 8000
# then visit http://localhost:8000/
```

## Build commands

```sh
zig build test           # unit + conformance tests
zig build fuzz           # random-input fuzzer (zig build fuzz -- [seed] [iterations])
zig build bench          # microbenchmarks (ReleaseFast)
zig build docs           # generate reference docs
zig build examples       # build all examples
zig build example-basic  # run a specific example (basic, typed, edit, spans, stream)
```

## Conformance

Validated against the full `test_parsing/` corpus of
[JSONTestSuite](https://github.com/nst/JSONTestSuite):

```
y_ (must parse):    95 of 95 pass, in both .json and .jsonc
n_ (must reject):  188 of 188 rejected
i_ (impl-defined):  35 of 35 match the pinned policy table
```

Every implementation-defined `i_` fixture is pinned to an explicit
accept/reject decision in `src/conformance.zig`; a corpus update that
adds a fixture without a decision fails the suite. The policy in brief:
out-of-range numbers are accepted (f64 fallback), invalid UTF-8 and lone
surrogates are rejected, UTF-16 input and BOMs are rejected, and 500
nested arrays are rejected by the default depth cap of 128.

The same suite also asserts that every `y_` fixture survives
parse -> encode -> parse with a deeply equal tree and emits
byte-identically through `Document`.

Reproduce with `zig build test`. The corpus is vendored under
`tests/corpus/JSONTestSuite/` alongside its upstream LICENSE.

## Performance

Run the bench yourself on your hardware with your inputs:

```sh
zig build bench
```

The harness reports min/p50/p99/max latency and throughput across multiple
samples with explicit warmup. See `bench/main.zig`.

On aarch64-linux, ReleaseFast, this lands at roughly:

| Benchmark | small (1.2 KB) | medium (22 KB) | large (391 KB) |
| --- | --- | --- | --- |
| parse (strict) | 3.58 us, 314 MB/s | 54.7 us, 396 MB/s | 1.13 ms, 338 MB/s |
| encode (compact) | 1.33 us, 643 MB/s | 11.5 us, 1361 MB/s | 413 us, 683 MB/s |
| Document parse+emit | 5.58 us, 201 MB/s | 88.6 us, 244 MB/s | 2.15 ms, 178 MB/s |

(p50 latency; encode throughput is measured against the bytes produced,
which for compact output is smaller than the input.)

The hot path uses SIMD string scanning in both the tokenizer and the
encoder's escape scan (`@Vector(16, u8)`). The fixtures are a
config-like document (small), a package lockfile (medium), and an array
of records (large); see `bench/fixtures/`.

## Memory model

`parse` and friends accept an `Allocator` (call it the parse arena). All
values, object keys, and any non-zero-copy strings live in that arena. To
free everything, deinit the arena - no need to walk the tree.

Strings parsed from the input may be zero-copy slices into the source
buffer when no escape processing is needed; otherwise they are
arena-allocated copies. Either way, keep the input alive for as long as
the parse tree is in use.

The document model also takes an arena. It owns the source string, the
node tree, and any edits. Each edit retains a new source/tree generation
in the arena, so memory grows with edit count; for long-lived many-edit
sessions, periodically emit and re-parse into a fresh arena.

## Examples

See `examples/` for runnable samples:

- `basic.zig` - dynamic parse and dotted-path access
- `typed.zig` - decode straight into a Zig struct
- `edit.zig` - lossless document edit + emit
- `spans.zig` - source spans and rich diagnostics
- `stream.zig` - incremental event reader, feed-core, NDJSON via ValueStream, skip-then-materialize
