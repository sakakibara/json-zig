//! JSON and JSONC parser.
//!
//! ```zig
//! const json = @import("json");
//!
//! var arena: std.heap.ArenaAllocator = .init(gpa);
//! defer arena.deinit();
//!
//! const v = try json.parse(arena.allocator(), src, .{});
//! const port = v.getT(i64, "server.port").?;
//! ```

const std = @import("std");
const decode_mod = @import("decode.zig");
const document_mod = @import("document.zig");
const encoder_mod = @import("encoder.zig");
const parser_mod = @import("parser.zig");
const stream_mod = @import("stream.zig");
const tokenizer_mod = @import("tokenizer.zig");
const value_mod = @import("value.zig");

/// Lossless document model: parse, edit, emit byte-identical when
/// unmodified. See `src/document.zig`.
pub const document = document_mod;
/// Lossless document model. See `src/document.zig`.
pub const Document = document_mod.Document;
/// Document edit error set (path resolution, literal validation,
/// comment-dialect, and depth failures).
pub const DocumentError = document_mod.Error;

/// Parse error set. `JsonParseError` covers all malformed input;
/// `NestingTooDeep` fires when containers nest past `ParseOptions.max_depth`.
/// Spans store u64 byte offsets, so there is no input-size cap.
pub const Error = parser_mod.Error;

/// One collected parse error: message, source span, and an optional
/// "did you mean" suggestion. Collect every error in one pass via
/// `ParseOptions.errors`:
///
/// ```zig
/// var errs: std.ArrayList(json.Diagnostic) = .empty;
/// defer errs.deinit(arena.allocator());
///
/// _ = json.parse(arena.allocator(), src, .{ .errors = &errs }) catch {
///     for (errs.items) |d| {
///         try d.render(writer, src);            // one-line form
///         try d.renderRich(writer, src);        // rustc-style excerpt
///     }
/// };
/// ```
///
/// Messages and suggestions are arena-allocated; they live as long as
/// the parse arena.
pub const Diagnostic = parser_mod.Diagnostic;

/// All knobs for `parse`. Default is `.{}` (strict JSON, depth 128).
pub const ParseOptions = parser_mod.ParseOptions;

/// Number materialization policy for the dynamic `Value` tree. `.typed`
/// (default) yields `.integer`/`.float`; `.raw` yields `.number_raw` with
/// the verbatim source lexeme. See `ParseOptions.number_mode`.
pub const NumberMode = parser_mod.NumberMode;

/// Token-level lexer. See `src/tokenizer.zig`.
pub const Tokenizer = tokenizer_mod.Tokenizer;
pub const Token = tokenizer_mod.Token;
pub const TokenKind = tokenizer_mod.Kind;
/// Input dialect: strict RFC 8259 JSON, or JSONC (JSON with comments).
pub const Dialect = tokenizer_mod.Dialect;

/// Streaming / SAX incremental event reader. See `src/stream.zig`.
pub const EventReader = stream_mod.EventReader;
pub const Event = stream_mod.Event;
pub const StreamOptions = stream_mod.StreamOptions;
pub const StreamError = stream_mod.StreamError;
/// Ergonomic record iterator over JSON arrays or NDJSON streams. See `src/stream.zig`.
pub const ValueStream = stream_mod.ValueStream;
pub const StreamShape = stream_mod.StreamShape;

/// Coerce a number event's raw lexeme to i128; returns null on overflow or
/// if the lexeme is not an integer literal.
pub const asInt = stream_mod.asInt;
/// Coerce a number event's raw lexeme to f64; returns null if the lexeme
/// cannot be parsed as a float.
pub const asFloat = stream_mod.asFloat;

/// Dynamic JSON value. See `src/value.zig`.
pub const Value = value_mod.Value;
/// Insertion-order-preserving string-keyed map used for objects.
pub const ObjectMap = value_mod.ObjectMap;
/// Source location of a token or parsed value.
pub const Span = value_mod.Span;
/// A map from dotted path to source span (e.g., "users[0].name" ->
/// Span). Array elements use `[N]` index segments; the root value's
/// path is the empty string. Populated by `parse` when
/// `ParseOptions.spans` is set; see `Value.locate` for the paired
/// lookup helper.
pub const Spans = value_mod.Spans;

/// Reader-input variants additionally surface the reader's allocation
/// failure path.
pub const ReaderError = parser_mod.ReaderError;

/// Parse a JSON (or JSONC) document from a byte slice. All allocations
/// land in `arena`; free the tree with `arena.deinit()`. Strings may be
/// zero-copy slices into `src`, so keep `src` alive while the tree is
/// in use. See `ParseOptions` for the option fields.
///
/// Any in-memory input is addressable: spans store u64 byte offsets, so
/// there is no input-size cap on parsing or on the opt-in spans map.
pub fn parse(arena: std.mem.Allocator, src: []const u8, options: ParseOptions) Error!Value {
    return parser_mod.parse(arena, src, options);
}

/// Reader-input variant of `parse`. Pulls the full input into arena memory
/// first, then calls `parse` over it. A complete contiguous buffer is
/// required anyway: zero-copy strings slice into it, and a document is only
/// valid once its final token is seen.
pub fn parseReader(arena: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) ReaderError!Value {
    return parser_mod.parseReader(arena, reader, options);
}

/// Typed-decode error set: `TypeMismatch`, `MissingField`,
/// `UnknownField`, `InvalidEnumValue`, `Overflow`, `OutOfMemory`.
pub const DecodeError = decode_mod.DecodeError;

/// Decode a parsed `Value` tree into `T` via comptime reflection.
/// Supports bool, ints (overflow-checked), floats, `[]const u8`,
/// slices, fixed-size arrays, optionals, nested structs, enums (string
/// name or integer tag), tagged unions via `json_tag`, embedded `Value`
/// fields (kept dynamic), custom `fromJson` hooks, and the
/// `json_rename` / `json_skip` / `json_flatten` annotations.
///
/// Number policy: float targets accept `.integer` values, but integer
/// targets do NOT accept `.float` -- `1e2` parses as `.float` and stays
/// one. In typed mode, integer literals in the range [minInt(i128),
/// maxInt(i128)] decode into any integer target that fits (overflow
/// returns `error.Overflow`). For u128 or literals beyond i128 range,
/// use `number_mode = .raw` so the lexeme decodes directly into the
/// target. JSON `null` decodes only into optional targets; anywhere else
/// it errors like an absent field. See `src/decode.zig`.
pub fn decode(comptime T: type, arena: std.mem.Allocator, value: Value, options: ParseOptions) DecodeError!T {
    return decode_mod.decode(T, arena, value, options);
}

/// Decode `src` directly into a `T`. Types without `Value` fields,
/// `fromJson` hooks, or tagged unions decode in a single streaming pass
/// with no intermediate `Value` tree; other types (and calls requesting
/// `options.spans`) parse to a tree first. Both paths accept and reject
/// identically. All allocations land in `arena`; string fields may be
/// zero-copy slices into `src`, so keep `src` alive while the result is
/// in use.
pub fn parseInto(comptime T: type, arena: std.mem.Allocator, src: []const u8, options: ParseOptions) (Error || DecodeError)!T {
    return decode_mod.parseInto(T, arena, src, options);
}

/// Reader-input variant of `parseInto`: drains the reader into arena
/// memory, then parses and decodes.
pub fn parseIntoReader(comptime T: type, arena: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) (ReaderError || DecodeError)!T {
    return decode_mod.parseIntoReader(T, arena, reader, options);
}

/// Encode failure: writer errors, plus `UnrepresentableFloat` for NaN
/// and +/-Inf `.float` values (JSON has no token for them), plus
/// `NestingTooDeep` when a hand-built tree exceeds the recursion limit,
/// plus `OutOfMemory`, reachable only from `encodeTyped`'s `toJson`
/// hooks (never from `encode`/`encodePretty`; Zig error sets are
/// per-function, not per-branch).
pub const EncodeError = encoder_mod.EncodeError;

/// Options for `encodePretty`. `indent` is the number of spaces per
/// nesting level.
pub const PrettyOptions = encoder_mod.PrettyOptions;

/// Encode a `Value` tree as compact JSON: no whitespace, object members
/// in insertion order. Output is always plain JSON (never comments or
/// trailing commas), regardless of the dialect the tree was parsed from.
pub fn encode(w: *std.Io.Writer, value: Value) EncodeError!void {
    return encoder_mod.encode(w, value);
}

/// Pretty-printed variant of `encode`: members one per line, indented
/// by `options.indent` spaces per level, `"key": value` members, and
/// closing brackets on their own line. Empty containers emit `{}`/`[]`.
pub fn encodePretty(w: *std.Io.Writer, value: Value, options: PrettyOptions) EncodeError!void {
    return encoder_mod.encodePretty(w, value, options);
}

/// Encode a typed Zig value as compact JSON, honoring the same
/// `json_rename` / `json_skip` / `json_flatten` / `json_tag` annotations
/// and `toJson` hooks that `decode` honors, so the output decodes back
/// via `parseInto(T, ...)`. Null optional fields are omitted entirely;
/// enums emit their tag name as a string; tagged unions emit the
/// discriminator member first with the payload's fields inline in the
/// same object. `arena` only backs `Value`s built by `toJson` hooks.
///
/// Annotations and hooks are read from `@TypeOf(value)`, so bind an
/// anonymous struct literal to the annotated type before passing it
/// (an anonymous literal's type carries no declarations).
pub fn encodeTyped(w: *std.Io.Writer, value: anytype, arena: std.mem.Allocator) EncodeError!void {
    return encoder_mod.encodeTyped(w, value, arena);
}

test "spans recorded per dotted path" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var spans: Spans = .empty;
    const src = "{\"server\": {\"port\": 8080}, \"tags\": [\"a\", \"b\"]}";
    const v = try parse(a, src, .{ .spans = &spans });
    const port = v.locate(spans, "server.port").?;
    try std.testing.expectEqual(@as(i64, 8080), port.value.integer);
    try std.testing.expectEqualStrings("8080", src[port.span.start..port.span.end]);
    const b = v.locate(spans, "tags[1]").?;
    try std.testing.expectEqualStrings("\"b\"", src[b.span.start..b.span.end]);
}

test "raw number mode preserves exact lexemes through the public API" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{\"big\":123456789012345678901234567890,\"e\":1e2,\"f\":1.50}";
    const v = try parse(a, src, .{ .number_mode = .raw });
    try std.testing.expectEqualStrings("123456789012345678901234567890", v.get("big").?.number_raw);
    // Typed access still coerces.
    try std.testing.expectEqual(@as(f64, 100.0), v.getT(f64, "e").?);
    // Encode re-emits verbatim.
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, v);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "parseReader equals parse" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{\"k\": [1, 2, 3]}";
    var r: std.Io.Reader = .fixed(src);
    const v = try parseReader(a, &r, .{});
    try std.testing.expectEqual(@as(i64, 3), v.getT(i64, "k[2]").?);
}

test "parseReader accepts jsonc dialect" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // JSONC: comments and trailing comma must be accepted.
    const src = "{ // port\n  \"port\": 8080, /* x */\n}";
    var r: std.Io.Reader = .fixed(src);
    const v = try parseReader(a, &r, .{ .dialect = .jsonc });
    try std.testing.expectEqual(@as(i64, 8080), v.getT(i64, "port").?);
}

// std.Io.Reader does not expose a limited/failing reader in the public API,
// so an explicit mid-stream-error test is not included. The drain uses
// allocRemaining, which propagates any StreamError returned by the underlying
// reader's stream vtable; error union composition via ReaderError covers it.

test "parseReader spans positions relative to drained buffer" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{\"x\": 42}";
    var spans: Spans = .empty;
    var r: std.Io.Reader = .fixed(src);
    const v = try parseReader(a, &r, .{ .spans = &spans });
    try std.testing.expectEqual(@as(i64, 42), v.getT(i64, "x").?);
    // Span offsets are into the drained buffer, which is byte-identical
    // to the original source.
    const s = v.locate(spans, "x").?;
    try std.testing.expectEqualStrings("42", src[s.span.start..s.span.end]);
}

test {
    std.testing.refAllDecls(@This());
    _ = decode_mod;
    _ = document_mod;
    _ = encoder_mod;
    _ = parser_mod;
    _ = stream_mod;
    _ = tokenizer_mod;
    _ = value_mod;
    _ = @import("levenshtein.zig");
    _ = @import("lex.zig");
}
