//! JSON / JSONC parser -- recursive descent over the token stream,
//! arena-allocated.
//!
//! Entry point: `parse(arena, input, options) -> Value`. On malformed
//! input: returns `error.JsonParseError`; on container nesting deeper
//! than `options.max_depth`: `error.NestingTooDeep`. Set
//! `options.errors` to a `*std.ArrayList(Diagnostic)` to recover
//! line/col/message for every error in one pass.

const std = @import("std");
const Allocator = std.mem.Allocator;

const lex = @import("lex.zig");
const tokenizer_mod = @import("tokenizer.zig");
const v = @import("value.zig");

pub const Value = v.Value;
pub const Spans = v.Spans;
pub const Dialect = tokenizer_mod.Dialect;

const RawToken = tokenizer_mod.RawToken;

/// Build a diagnostic `Span` from a raw token's byte range. u64 offsets
/// address any in-memory input, so this never narrows or saturates.
fn diagSpan(t: RawToken) v.Span {
    return .{ .start = t.start, .end = t.end };
}

/// One collected parse error: what went wrong and where.
///
/// `span` records the offending byte range; line/col are derived on demand
/// from the span and source. The `renderRich` caret alignment counts bytes,
/// not codepoints or display columns: tabs and multi-byte UTF-8 characters
/// earlier on the line shift the caret relative to what a terminal renders.
pub const Diagnostic = struct {
    /// Arena-allocated. Lifetime: the parse arena.
    message: []const u8,
    /// Source byte range of the offending token. Zero-length (start ==
    /// end) when the error site has no token, e.g. unexpected EOF.
    span: v.Span,
    /// "Did you mean X?" suggestion. Set when a typo'd key or value is
    /// rejected with a close-enough candidate. Arena-allocated.
    suggestion: ?[]const u8 = null,

    /// Single-line summary. Line/col are derived from the span offset
    /// against `source` (the original bytes passed to `parse`).
    pub fn render(self: Diagnostic, writer: *std.Io.Writer, source: []const u8) !void {
        const lc = self.span.lineCol(source);
        try writer.print("error at {d}:{d}: {s}", .{ lc.line, lc.col, self.message });
    }

    /// Multi-line rich form. Emits a rustc-style block: header, source
    /// line with caret underline, suggestion. Caller provides the
    /// original source bytes (the same slice passed to `parse`).
    /// ASCII only -- no terminal color escapes.
    pub fn renderRich(self: Diagnostic, w: *std.Io.Writer, source: []const u8) !void {
        const lc = self.span.lineCol(source);
        try w.print("error at {d}:{d}: {s}\n", .{ lc.line, lc.col, self.message });

        // Source snippet (only if line/col and source bounds match).
        blk: {
            var line_start: usize = 0;
            var lineno: u32 = 1;
            var i: usize = 0;
            while (i < source.len and lineno < lc.line) : (i += 1) {
                if (source[i] == '\n') {
                    lineno += 1;
                    line_start = i + 1;
                }
            }
            if (lineno != lc.line) break :blk;
            var line_end = line_start;
            while (line_end < source.len and source[line_end] != '\n') line_end += 1;

            const line_text = source[line_start..line_end];
            try w.print("  |\n{d:>3} | {s}\n  | ", .{ lc.line, line_text });

            // Caret column and width, both clamped to the line end (an
            // EOF span lands one column past the last byte).
            const start: usize = @intCast(self.span.start);
            const col0 = if (start >= line_start) @min(start - line_start, line_text.len) else 0;
            const end = @min(@as(usize, @intCast(self.span.end)), line_end);
            const carets = if (end > start) end - start else 1;
            var c: usize = 0;
            while (c < col0) : (c += 1) try w.writeByte(' ');
            var k: usize = 0;
            while (k < carets) : (k += 1) try w.writeByte('^');
            try w.writeByte('\n');
        }

        if (self.suggestion) |s| {
            try w.print("  = help: did you mean `{s}`?\n", .{s});
        }
    }
};

pub const Error = error{
    JsonParseError,
    NestingTooDeep,
} || Allocator.Error;

/// Reader-input variants additionally surface the reader's allocation
/// failure path.
pub const ReaderError = Error || std.Io.Reader.LimitedAllocError;

/// Reader-input variant of `parse`. Pulls the full input into arena memory
/// first, then calls `parse` over it. A complete contiguous buffer is
/// required anyway: zero-copy strings slice into it, and a document is only
/// valid once its final token is seen.
pub fn parseReader(arena: Allocator, reader: *std.Io.Reader, options: ParseOptions) ReaderError!Value {
    const input = try reader.allocRemaining(arena, .unlimited);
    return parse(arena, input, options);
}

/// Number materialization policy for the dynamic `Value` tree. See
/// `ParseOptions.number_mode`.
pub const NumberMode = enum { typed, raw };

/// All knobs for `parse`. Default `.{}` is the strict-JSON common case.
/// Defined here; re-exported by `json.zig` as `json.ParseOptions` (the
/// canonical name callers should use).
pub const ParseOptions = struct {
    /// When non-null, parser appends each error and continues via
    /// recovery (parsing resumes at the next `,` / `]` / `}` at the
    /// same nesting level), so a single pass reports every error in
    /// the document. Returns `error.JsonParseError` at the end if any
    /// errors were collected; the partially-built tree is discarded,
    /// only the diagnostics survive. When null, parser bails on the
    /// first error with no diagnostic captured.
    ///
    /// Ownership: appended entries (list nodes, messages, suggestions)
    /// are allocated in the parse arena. Deinit the list with that
    /// arena's allocator, or simply drop it when the arena frees --
    /// entries are dangling once the arena is gone.
    errors: ?*std.ArrayList(Diagnostic) = null,

    /// If non-null, populated with one Span per emitted Value, keyed by
    /// dotted path. Array elements use `[N]` index segments. The root
    /// value's path is the empty string `""`. Scalars span their token;
    /// arrays and objects span from opening to closing bracket inclusive.
    /// Values substituted by error recovery (broken elements replaced
    /// with `.null`) record no span; values that parsed cleanly in the
    /// same pass still do. Path keys are arena-allocated and live as
    /// long as the value tree.
    ///
    /// The map stores u64 byte offsets, so any in-memory input is
    /// addressable without a size cap.
    spans: ?*v.Spans = null,

    /// Decode-only. When true, JSON keys absent from a target struct are
    /// silently dropped instead of erroring. Ignored by dynamic `parse`.
    ignore_unknown_fields: bool = false,

    /// Strict RFC 8259 JSON, or JSONC (comments and trailing commas).
    dialect: Dialect = .json,

    /// How numbers materialize in the dynamic `Value` tree.
    ///
    /// - `.typed` (default): integer-syntax numbers parse to `.integer`
    ///   (i128 range; overflow beyond i128 falls back to f64); float-syntax
    ///   numbers parse to `.float`. Lossless for integers up to i128 max.
    ///   Float-valued lexemes like `1e2` are always `.float`.
    /// - `.raw`: every number becomes a `.number_raw` holding the
    ///   verbatim source lexeme (zero-copy slice into the input), so the
    ///   exact digits are preserved. Typed access still works via
    ///   `Value.getT` (which parses the lexeme on demand) and the encoder
    ///   re-emits the bytes verbatim. Required for u128 or values beyond
    ///   i128 range.
    number_mode: NumberMode = .typed,

    /// Maximum container (array/object) nesting depth. Exceeding it
    /// returns `error.NestingTooDeep`. The default 128 is safe on any
    /// supported stack size.
    ///
    /// The recursive tree parser consumes one host stack frame per level,
    /// so the effective depth it honors is
    /// `min(max_depth, recursive_depth_ceiling)` (the ceiling is 128):
    /// raising `max_depth` past the ceiling caps the parser at the ceiling
    /// and returns `error.NestingTooDeep` rather than overflowing the
    /// stack -- it can never crash. For input nested deeper than the
    /// ceiling, use the iterative streaming `EventReader` / `materialize`:
    /// their stack is heap-allocated, so they have no hard ceiling and
    /// `StreamOptions.max_depth` (also 128 by default) can be raised past 128.
    max_depth: usize = 128,
};

const MAX_RECOVERY_ERRORS: usize = 100;

/// Options-aware parse. See `ParseOptions`.
///
/// Token length: `parse` operates on a fully-materialized caller-owned slice
/// and imposes no per-token length limit (there is no `max_token_len`
/// equivalent here). For untrusted input from unbounded sources where a single
/// token could be arbitrarily long, use the streaming `EventReader` instead:
/// its `StreamOptions.max_token_len` (default 16 MiB) bounds how much memory
/// a single string or number token can consume before `error.TokenTooLong` is
/// returned.
pub fn parse(arena: Allocator, input: []const u8, options: ParseOptions) Error!Value {
    var p = Parser{
        .arena = arena,
        .input = input,
        .tokenizer = .init(input, options.dialect),
        .options = options,
    };
    return p.parseDocument();
}

/// Decode a string token's content bytes (the bytes between the quotes,
/// quotes excluded) into their unescaped form. `content` must already be
/// well-formed: escape-free content is returned as a zero-copy slice;
/// otherwise the unescaped bytes are arena-allocated. On malformed input
/// yields `error.JsonParseError` rather than producing wrong bytes.
pub fn decodeStringContent(arena: Allocator, content: []const u8) error{ OutOfMemory, JsonParseError }![]const u8 {
    if (std.mem.indexOfScalar(u8, content, '\\') == null) return content;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    // Runs between escapes are copied verbatim: the content is already
    // validated, so only escape errors can occur here.
    lex.unescape(false, arena, content, &buf) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.JsonParseError,
    };
    return buf.toOwnedSlice(arena);
}

pub const Parser = struct {
    arena: Allocator,
    input: []const u8,
    tokenizer: tokenizer_mod.Tokenizer,
    options: ParseOptions,
    /// Errors recorded during this parse. The caller's error list may
    /// carry entries from earlier parses, so the end-of-document check
    /// and the recovery cap count this, not the list length.
    error_count: usize = 0,
    /// Kind of the token a just-failed value position choked on, when
    /// that token is itself a separator or closer. Lets recovery treat
    /// it as the terminator instead of skipping past the next one
    /// (which would swallow the following clean element).
    fail_kind: ?tokenizer_mod.Kind = null,
    /// Dotted path of the value currently being parsed (e.g.
    /// "users[0].name"; empty at the root). Container parsers push key /
    /// index segments before recursing and restore the length on exit.
    /// Only maintained when `options.spans` is set.
    current_path: std.ArrayList(u8) = .empty,

    fn parseDocument(self: *Parser) Error!Value {
        const t = (try self.next()) orelse return self.failEof("unexpected end of input");
        const value = try self.parseValue(t, 0);
        if (try self.next()) |extra| return self.fail(diagSpan(extra), "unexpected token after top-level value");
        // Not a funnel site: recovered errors were each recorded at
        // their origin; this only reports that some were collected.
        if (self.error_count > 0) return error.JsonParseError;
        return value;
    }

    // Error funnel

    /// Every parse failure routes through here (or a wrapper below):
    /// records a Diagnostic when an error sink is set, then returns
    /// `error.JsonParseError`. With no sink this is allocation-free.
    fn fail(self: *Parser, span: v.Span, comptime msg: []const u8) Error {
        self.error_count += 1;
        self.fail_kind = null;
        if (self.options.errors) |list| {
            const owned = self.arena.dupe(u8, msg) catch return error.OutOfMemory;
            list.append(self.arena, .{ .message = owned, .span = span }) catch return error.OutOfMemory;
        }
        return error.JsonParseError;
    }

    fn failFmt(self: *Parser, span: v.Span, comptime fmt: []const u8, args: anytype) Error {
        self.error_count += 1;
        self.fail_kind = null;
        if (self.options.errors) |list| {
            const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
            list.append(self.arena, .{ .message = msg, .span = span }) catch return error.OutOfMemory;
        }
        return error.JsonParseError;
    }

    /// Effective recursive depth bound: the smaller of the caller's
    /// `max_depth` and the stack-safe `recursive_depth_ceiling`. Capping
    /// here is what makes a raised `max_depth` return `NestingTooDeep`
    /// instead of overflowing the host stack.
    pub fn depthLimit(self: *const Parser) usize {
        return @min(self.options.max_depth, v.recursive_depth_ceiling);
    }

    /// Depth-guard failure: records a diagnostic (the guard is still an
    /// error the module promises line/col for) but returns the distinct
    /// `error.NestingTooDeep`, which recovery never swallows.
    fn failDepth(self: *Parser, span: v.Span) Error {
        self.error_count += 1;
        if (self.options.errors) |list| {
            const msg = std.fmt.allocPrint(self.arena, "nesting depth exceeds limit ({d})", .{self.depthLimit()}) catch return error.OutOfMemory;
            list.append(self.arena, .{ .message = msg, .span = span }) catch return error.OutOfMemory;
        }
        return error.NestingTooDeep;
    }

    /// Failure with no token to point at: a zero-length span at the
    /// tokenizer's current position (end of input).
    fn failEof(self: *Parser, comptime msg: []const u8) Error {
        const off = self.tokenizer.pos;
        return self.fail(.{ .start = off, .end = off }, msg);
    }

    /// Lexer-level `invalid` token: classify by leading byte for a more
    /// specific message.
    fn failInvalidToken(self: *Parser, t: RawToken) Error {
        const span = diagSpan(t);
        return switch (self.input[t.start]) {
            '"' => self.fail(span, "unterminated string"),
            '/' => if (self.options.dialect == .json)
                self.fail(span, "comments not allowed in strict json")
            else
                self.fail(span, "unterminated or malformed comment"),
            '-', '+', '.', '0'...'9' => self.fail(span, "invalid number"),
            'A'...'Z', 'a'...'z', '_' => self.failFmt(span, "invalid literal `{s}`", .{self.input[t.start..t.end]}),
            else => self.fail(span, "unexpected character"),
        };
    }

    // Span recording

    /// Append `.segment` to the current path (separator dropped at the
    /// root), returning the previous length for `popPath`. No-op when
    /// spans are off.
    fn pushPath(self: *Parser, segment: []const u8) Error!usize {
        if (self.options.spans == null) return 0;
        const prev_len = self.current_path.items.len;
        if (prev_len > 0) try self.current_path.append(self.arena, '.');
        try self.current_path.appendSlice(self.arena, segment);
        return prev_len;
    }

    /// Append a `[N]` index segment (no separator before it).
    fn pushIndex(self: *Parser, idx: usize) Error!usize {
        if (self.options.spans == null) return 0;
        const prev_len = self.current_path.items.len;
        try self.current_path.print(self.arena, "[{d}]", .{idx});
        return prev_len;
    }

    fn popPath(self: *Parser, prev_len: usize) void {
        if (self.options.spans == null) return;
        self.current_path.shrinkRetainingCapacity(prev_len);
    }

    /// Record the just-parsed value's span under the current path. The
    /// path is duped into the arena, so it outlives the path buffer.
    /// Duplicate paths (duplicate object keys) overwrite, matching the
    /// value tree's last-wins semantics. No-op when spans are off.
    ///
    /// Offsets are stored as u64, so any in-memory input is addressable
    /// without a size cap. (Reached only when `ParseOptions.spans` is set.)
    fn recordSpan(self: *Parser, start: RawToken, end: usize) Error!void {
        const sm = self.options.spans orelse return;
        const path = try self.arena.dupe(u8, self.current_path.items);
        try sm.put(self.arena, path, .{ .start = start.start, .end = end });
    }

    // Recovery

    const Terminator = enum { comma, close, eof };

    /// Recovery gate. `err` is the failure the caller just caught
    /// (already recorded by the funnel). Recovery requires an error
    /// sink with room under the cap and only applies to
    /// `JsonParseError`; anything else propagates.
    fn recoverable(self: *Parser, err: Error) Error!void {
        if (err != error.JsonParseError) return err;
        if (self.options.errors == null) return err;
        if (self.error_count >= MAX_RECOVERY_ERRORS) return err;
    }

    /// Gate + skip for in-container recovery. On success the broken
    /// region has been consumed up to and including the next
    /// `,` / `]` / `}` at the caller's nesting level. When the failure
    /// site was itself a separator or closer (see `fail_kind`), that
    /// token already terminates the region and nothing is skipped.
    fn recoverSkip(self: *Parser, err: Error) Error!Terminator {
        try self.recoverable(err);
        if (self.fail_kind) |kind| {
            self.fail_kind = null;
            switch (kind) {
                .comma => return .comma,
                .array_end, .object_end => return .close,
                else => {},
            }
        }
        return self.skipBroken();
    }

    /// Consume raw tokens until a separator or closer at the current
    /// nesting level. Nested containers are skipped whole via bracket
    /// balance; strings and comments are single tokens, so their
    /// contents never confuse the balance. Every iteration consumes a
    /// token, so the skip always makes progress toward EOF.
    fn skipBroken(self: *Parser) Terminator {
        var balance: usize = 0;
        while (self.tokenizer.next()) |t| {
            switch (t.kind) {
                .array_begin, .object_begin => balance += 1,
                .array_end, .object_end => {
                    if (balance == 0) return .close;
                    balance -= 1;
                },
                .comma => if (balance == 0) return .comma,
                else => {},
            }
        }
        return .eof;
    }

    /// Pull the next structural token: comments are skipped, lexer-level
    /// `invalid` tokens become a parse error, EOF is null.
    pub fn next(self: *Parser) Error!?RawToken {
        while (self.tokenizer.nextRaw()) |t| {
            switch (t.kind) {
                .comment => continue,
                .invalid => return self.failInvalidToken(t),
                else => return t,
            }
        }
        return null;
    }

    /// Parse the value introduced by `t`. `depth` counts enclosing
    /// containers; opening one past `depthLimit()` fails before any nested
    /// token is pulled, so the guard fires even on unbalanced input. The
    /// limit is `min(max_depth, recursive_depth_ceiling)`, so this guard
    /// also bounds host-stack recursion -- it can never overflow.
    pub fn parseValue(self: *Parser, t: RawToken, depth: usize) Error!Value {
        var end: usize = t.end;
        const value: Value = switch (t.kind) {
            .literal_null => .null,
            .literal_true => .{ .bool = true },
            .literal_false => .{ .bool = false },
            .number => try self.parseNumber(t),
            .string => .{ .string = try self.decodeString(t) },
            .array_begin => blk: {
                if (depth >= self.depthLimit()) return self.failDepth(diagSpan(t));
                break :blk try self.parseArray(depth + 1, &end);
            },
            .object_begin => blk: {
                if (depth >= self.depthLimit()) return self.failDepth(diagSpan(t));
                break :blk try self.parseObject(depth + 1, &end);
            },
            else => {
                // A separator/closer in value position terminates the
                // broken region itself; mark it so recovery does not
                // skip past the next separator.
                const err = self.fail(diagSpan(t), "expected value");
                self.fail_kind = t.kind;
                return err;
            },
        };
        try self.recordSpan(t, end);
        return value;
    }

    /// Each loop iteration handles one element plus its separator. A
    /// failure in either position records a diagnostic and, with an
    /// error sink set, recovers: the broken element becomes `.null` and
    /// parsing resumes after the next `,` (or the array closes).
    ///
    /// `end_out` receives the container's end offset for span recording:
    /// just past the closing `]` (the tokenizer's position after the last
    /// consumed token; on recovery via EOF, the end of input).
    fn parseArray(self: *Parser, depth: usize, end_out: *usize) Error!Value {
        defer end_out.* = self.tokenizer.pos;
        var items: std.ArrayList(Value) = .empty;
        // Most arrays hold a handful of elements; a small constant pre-size
        // lets them skip the empty->1->2->4 realloc chain. Larger arrays
        // still grow geometrically from here, just fewer times.
        try items.ensureTotalCapacity(self.arena, 8);
        var at_first = true;
        loop: while (true) {
            const t_opt = self.next() catch |err| switch (try self.recoverSkip(err)) {
                .comma => {
                    try items.append(self.arena, .null);
                    at_first = false;
                    continue :loop;
                },
                .close, .eof => {
                    try items.append(self.arena, .null);
                    break :loop;
                },
            };
            const t = t_opt orelse return self.failEof("unexpected end of input in array");
            if (t.kind == .array_end) {
                if (at_first or self.options.dialect == .jsonc) break :loop;
                // The closer is already consumed, so recovery here is
                // just "close the array" -- no skip, no null element.
                try self.recoverable(self.fail(diagSpan(t), "trailing comma not allowed in strict json"));
                break :loop;
            }
            at_first = false;

            const prev = try self.pushIndex(items.items.len);
            defer self.popPath(prev);
            const value = self.parseValue(t, depth) catch |err| switch (try self.recoverSkip(err)) {
                .comma => {
                    try items.append(self.arena, .null);
                    continue :loop;
                },
                .close, .eof => {
                    try items.append(self.arena, .null);
                    break :loop;
                },
            };
            try items.append(self.arena, value);

            const sep_opt = self.next() catch |err| switch (try self.recoverSkip(err)) {
                .comma => continue :loop,
                .close, .eof => break :loop,
            };
            const sep = sep_opt orelse return self.failEof("unexpected end of input in array");
            if (sep.kind == .array_end) break :loop;
            if (sep.kind != .comma) {
                const err = self.fail(diagSpan(sep), "expected ',' or ']' in array");
                switch (try self.recoverSkip(err)) {
                    .comma => continue :loop,
                    .close, .eof => break :loop,
                }
            }
        }
        return .{ .array = try items.toOwnedSlice(self.arena) };
    }

    /// Mirror of `parseArray`: one member plus separator per iteration.
    /// When the member's key decoded before the failure, recovery binds
    /// it to `.null`; a broken key skips the member entirely.
    ///
    /// `end_out`: see `parseArray`.
    fn parseObject(self: *Parser, depth: usize, end_out: *usize) Error!Value {
        defer end_out.* = self.tokenizer.pos;
        var map: v.ObjectMap = .empty;
        // Same rationale as parseArray: a small constant pre-size spares
        // most objects the empty-map rehash chain.
        try map.ensureTotalCapacity(self.arena, 8);
        var at_first = true;
        loop: while (true) {
            const t_opt = self.next() catch |err| switch (try self.recoverSkip(err)) {
                .comma => {
                    at_first = false;
                    continue :loop;
                },
                .close, .eof => break :loop,
            };
            const t = t_opt orelse return self.failEof("unexpected end of input in object");
            if (t.kind == .object_end) {
                if (at_first or self.options.dialect == .jsonc) break :loop;
                try self.recoverable(self.fail(diagSpan(t), "trailing comma not allowed in strict json"));
                break :loop;
            }
            at_first = false;

            var key: ?[]const u8 = null;
            const value = self.parseMember(t, depth, &key) catch |err| switch (try self.recoverSkip(err)) {
                .comma => {
                    if (key) |k| try map.put(self.arena, k, .null);
                    continue :loop;
                },
                .close, .eof => {
                    if (key) |k| try map.put(self.arena, k, .null);
                    break :loop;
                },
            };
            // Duplicate key: `put` overwrites in place, keeping the
            // original insertion position (last value wins).
            try map.put(self.arena, key.?, value);

            const sep_opt = self.next() catch |err| switch (try self.recoverSkip(err)) {
                .comma => continue :loop,
                .close, .eof => break :loop,
            };
            const sep = sep_opt orelse return self.failEof("unexpected end of input in object");
            if (sep.kind == .object_end) break :loop;
            if (sep.kind != .comma) {
                const err = self.fail(diagSpan(sep), "expected ',' or '}' in object");
                switch (try self.recoverSkip(err)) {
                    .comma => continue :loop,
                    .close, .eof => break :loop,
                }
            }
        }
        return .{ .object = map };
    }

    /// One `"key": value` object member, starting from its key token
    /// `t`. `key_out` is set as soon as the key decodes so that the
    /// caller's recovery can still bind it when a later step fails.
    fn parseMember(self: *Parser, t: RawToken, depth: usize, key_out: *?[]const u8) Error!Value {
        if (t.kind != .string) return self.fail(diagSpan(t), "expected object key");
        key_out.* = try self.decodeString(t);
        const colon = (try self.next()) orelse return self.failEof("unexpected end of input in object");
        if (colon.kind != .colon) return self.fail(diagSpan(colon), "expected ':' after object key");
        const val_tok = (try self.next()) orelse return self.failEof("unexpected end of input in object");
        const prev = try self.pushPath(key_out.*.?);
        defer self.popPath(prev);
        return self.parseValue(val_tok, depth);
    }

    /// Integer-syntax lexemes (no `.`/`e`/`E`) become `.integer`, falling
    /// back to `.float` on i128 overflow; everything else is `.float`.
    pub fn parseNumber(self: *Parser, t: RawToken) Error!Value {
        const raw = self.input[t.start..t.end];
        // Raw mode preserves the verbatim lexeme; the lexer already
        // validated it as a well-formed number, so no parsing is needed.
        if (self.options.number_mode == .raw) return .{ .number_raw = raw };
        if (std.mem.indexOfAny(u8, raw, ".eE") == null) {
            if (parseIntFast(raw)) |n| return .{ .integer = n };
            // >18 digits or the fast path declined: try full i128 parse.
            // Overflow falls through to .float so astronomically large
            // integer literals (beyond i128) still parse without error.
            if (std.fmt.parseInt(i128, raw, 10)) |n| {
                return .{ .integer = n };
            } else |err| switch (err) {
                error.Overflow => {},
                error.InvalidCharacter => return self.fail(diagSpan(t), "invalid number"),
            }
        }
        // The lexer's RFC 8259 number validation guarantees that `raw`
        // contains only valid float chars, so parseFloat succeeds or
        // returns inf on magnitude overflow -- it never errors here.
        // The catch is kept as a defensive fallback.
        const f = std.fmt.parseFloat(f64, raw) catch return self.fail(diagSpan(t), "invalid number");
        return .{ .float = f };
    }

    /// Decode a string token's body. Escape-free strings are returned as
    /// zero-copy slices into the input; otherwise the unescaped bytes are
    /// arena-allocated. Either way the content is validated: no raw
    /// control bytes, valid UTF-8, well-formed escapes. Diagnostics
    /// underline the whole string token.
    pub fn decodeString(self: *Parser, t: RawToken) Error![]const u8 {
        const span = diagSpan(t);
        const body = self.input[t.start + 1 .. t.end - 1];
        if (std.mem.indexOfScalar(u8, body, '\\') == null) {
            try self.validateRaw(span, body);
            return body;
        }

        var buf: std.ArrayList(u8) = .empty;
        lex.unescape(true, self.arena, body, &buf) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TruncatedEscape => self.fail(span, "truncated escape in string"),
            error.InvalidEscape => self.fail(span, "invalid escape in string"),
            error.InvalidCodepoint => self.fail(span, "invalid \\u escape"),
            error.TruncatedUnicodeEscape, error.InvalidHexDigit => self.fail(span, "truncated or invalid \\u escape"),
            error.LoneLowSurrogate => self.fail(span, "lone low surrogate in \\u escape"),
            error.UnpairedHighSurrogate => self.fail(span, "unpaired high surrogate in \\u escape"),
            error.ControlCharacter => self.fail(span, "control character in string"),
            error.InvalidUtf8 => self.fail(span, "invalid utf-8 in string"),
        };
        return try buf.toOwnedSlice(self.arena);
    }

    /// Validate an escape-free string body: no raw control bytes, valid UTF-8.
    fn validateRaw(self: *Parser, span: v.Span, body: []const u8) Error!void {
        for (body) |c| {
            if (c < 0x20) return self.fail(span, "control character in string");
        }
        if (!std.unicode.utf8ValidateSlice(body)) return self.fail(span, "invalid utf-8 in string");
    }
};

/// Fast path for a decimal integer lexeme already validated by the lexer
/// (optional leading `-`, then `0` or a non-zero-leading digit run, no
/// `.`/`e`/`E`). Returns the i128 value when the digit run is at most 18
/// long, where the magnitude (< 10^18) always fits i128 with room to spare
/// so no per-step overflow check is needed. Returns null for >18 digits or
/// a lone `-` (the empty case can't occur for a valid lexeme), deferring
/// to the parseInt(i128) caller for the i128-max boundary decision.
/// Bit-identical to parseInt(i128, raw, 10) for every input it accepts.
fn parseIntFast(raw: []const u8) ?i128 {
    var i: usize = 0;
    const neg = raw.len > 0 and raw[0] == '-';
    if (neg) i = 1;
    const digits = raw[i..];
    if (digits.len == 0 or digits.len > 18) return null;
    var acc: u64 = 0;
    for (digits) |c| acc = acc * 10 + (c - '0');
    const signed: i128 = @intCast(acc);
    return if (neg) -signed else signed;
}

// Tests

const testing = std.testing;

fn parseTest(a: std.mem.Allocator, src: []const u8) !Value {
    return parse(a, src, .{});
}

test "parse scalars at top level" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectEqual(@as(i128, 42), (try parseTest(a, "42")).integer);
    try std.testing.expectEqual(@as(f64, 1.5), (try parseTest(a, "1.5")).float);
    try std.testing.expectEqual(true, (try parseTest(a, "true")).bool);
    try std.testing.expect((try parseTest(a, "null")) == .null);
    try std.testing.expectEqualStrings("hi", (try parseTest(a, "\"hi\"")).string);
}

test "number policy: integer range extends to i128" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // i64 max still parses as .integer (and stays in range for i128).
    try std.testing.expectEqual(@as(i128, 9223372036854775807), (try parseTest(a, "9223372036854775807")).integer);
    // One above i64 max now parses as .integer (fits i128), not .float.
    try std.testing.expect((try parseTest(a, "9223372036854775808")) == .integer);
    // i128 max parses as .integer; one above overflows to .float.
    try std.testing.expect((try parseTest(a, "170141183460469231731687303715884105727")) == .integer);
    try std.testing.expect((try parseTest(a, "170141183460469231731687303715884105728")) == .float);
    // Float-syntax lexemes are always .float regardless of value.
    try std.testing.expect((try parseTest(a, "1e2")) == .float);
    try std.testing.expectEqual(@as(i128, 0), (try parseTest(a, "-0")).integer);
}

test "parseIntFast matches parseInt across the accepted range" {
    const cases = [_][]const u8{
        "0",                   "-0",                  "1",
        "-1",                  "9",                   "10",
        "100",                 "-100",                "999999999999999999", // 18 nines
        "-999999999999999999", "123456789012345678",  "-123456789012345678",
    };
    for (cases) |s| {
        const fast = parseIntFast(s).?;
        const slow = try std.fmt.parseInt(i128, s, 10);
        try std.testing.expectEqual(slow, fast);
    }
    // 19-digit lexemes decline the fast path so the parseInt(i128) boundary
    // policy stays authoritative.
    try std.testing.expect(parseIntFast("9223372036854775807") == null);
    try std.testing.expect(parseIntFast("9223372036854775808") == null);
    try std.testing.expect(parseIntFast("-9223372036854775808") == null);
    try std.testing.expect(parseIntFast("1000000000000000000") == null); // 19 digits
    try std.testing.expect(parseIntFast("-") == null);
}

test "raw number mode preserves exact lexeme" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v2 = try parse(a, "{\"big\": 123456789012345678901234567890, \"e\": 1e2, \"f\": 1.50}", .{ .number_mode = .raw });
    try std.testing.expectEqualStrings("123456789012345678901234567890", v2.get("big").?.number_raw);
    try std.testing.expectEqualStrings("1e2", v2.get("e").?.number_raw);
    try std.testing.expectEqualStrings("1.50", v2.get("f").?.number_raw);
}

test "raw number getT still coerces to typed" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v2 = try parse(a, "{\"n\": 42, \"x\": 1.5}", .{ .number_mode = .raw });
    try std.testing.expectEqual(@as(i64, 42), v2.getT(i64, "n").?);
    try std.testing.expectEqual(@as(f64, 1.5), v2.getT(f64, "x").?);
}

test "default mode unchanged: numbers are typed" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v2 = try parse(a, "{\"n\": 42, \"x\": 1.5}", .{});
    try std.testing.expect(v2.get("n").? == .integer);
    try std.testing.expect(v2.get("x").? == .float);
    try std.testing.expectEqual(@as(i128, 42), v2.get("n").?.integer);
}

test "raw number mode: top-level scalar and array elements" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const scalar = try parse(a, "9223372036854775808", .{ .number_mode = .raw });
    try std.testing.expectEqualStrings("9223372036854775808", scalar.number_raw);
    const arr = try parse(a, "[1, -2.5e-3, 0]", .{ .number_mode = .raw });
    try std.testing.expectEqualStrings("1", arr.array[0].number_raw);
    try std.testing.expectEqualStrings("-2.5e-3", arr.array[1].number_raw);
    try std.testing.expectEqualStrings("0", arr.array[2].number_raw);
}

test "duplicate keys: last wins" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v2 = try parseTest(ar.allocator(), "{\"a\":1,\"a\":2}");
    try std.testing.expectEqual(@as(i64, 2), v2.getT(i64, "a").?);
}

test "string escapes incl surrogate pair" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v2 = try parseTest(a, "\"\\u0041\\n\\\\ \\ud834\\udd1e\"");
    try std.testing.expectEqualStrings("A\n\\ \xf0\x9d\x84\x9e", v2.string);
    try std.testing.expectError(error.JsonParseError, parseTest(a, "\"\\ud834\""));
    try std.testing.expectError(error.JsonParseError, parseTest(a, "\"\\x\""));
}

test "zero-copy strings when no escapes" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const src = "\"plain\"";
    const v2 = try parseTest(ar.allocator(), src);
    try std.testing.expectEqual(@intFromPtr(src.ptr + 1), @intFromPtr(v2.string.ptr));
}

test "nesting depth guard" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var buf: [300]u8 = undefined;
    @memset(buf[0..129], '[');
    try std.testing.expectError(error.NestingTooDeep, parse(a, buf[0..129], .{}));
    @memset(buf[0..128], '[');
    buf[128] = '1';
    @memset(buf[129 .. 129 + 128], ']');
    _ = try parse(a, buf[0 .. 129 + 128], .{});
}

test "raised max_depth never overflows the stack: deep input yields NestingTooDeep" {
    // 200k levels of '[' with max_depth raised to a million. The recursive
    // parser is capped at recursive_depth_ceiling regardless of max_depth,
    // so this returns the error well before any stack frame past the ceiling
    // is pushed -- it must never SIGSEGV. (Run under ReleaseSafe to confirm.)
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const deep = try a.alloc(u8, 200_000);
    @memset(deep, '[');
    try std.testing.expectError(error.NestingTooDeep, parse(a, deep, .{ .max_depth = 1_000_000 }));
}

test "effective depth is min(max_depth, ceiling)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // One level past the ceiling fails even with max_depth far above it.
    const over = v.recursive_depth_ceiling + 1;
    const buf = try a.alloc(u8, over);
    @memset(buf, '[');
    try std.testing.expectError(error.NestingTooDeep, parse(a, buf, .{ .max_depth = 1_000_000 }));
    // Exactly at the ceiling, balanced, parses (the guard fires on the
    // (ceiling+1)-th open, not the ceiling-th).
    const balanced = try a.alloc(u8, 2 * v.recursive_depth_ceiling + 1);
    @memset(balanced[0..v.recursive_depth_ceiling], '[');
    balanced[v.recursive_depth_ceiling] = '1';
    @memset(balanced[v.recursive_depth_ceiling + 1 ..], ']');
    _ = try parse(a, balanced, .{ .max_depth = 1_000_000 });
}

test "strict json rejects jsonc syntax" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(error.JsonParseError, parseTest(a, "[1,2,]"));
    try std.testing.expectError(error.JsonParseError, parseTest(a, "[1] // c"));
}

test "jsonc dialect accepts comments and trailing commas" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v2 = try parse(ar.allocator(), "{\n  // port\n  \"port\": 8080, /* x */\n}", .{ .dialect = .jsonc });
    try std.testing.expectEqual(@as(i64, 8080), v2.getT(i64, "port").?);
}

test "trailing garbage rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectError(error.JsonParseError, parseTest(ar.allocator(), "1 2"));
}

test "empty object and array" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const obj = try parseTest(a, "{}");
    try testing.expect(obj == .object);
    try testing.expectEqual(@as(usize, 0), obj.object.count());
    const arr = try parseTest(a, "[]");
    try testing.expect(arr == .array);
    try testing.expectEqual(@as(usize, 0), arr.array.len);
}

test "nested mixed structure" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const src =
        "{\"users\":[{\"name\":\"ada\",\"admin\":true},{\"name\":\"bob\",\"admin\":false}]," ++
        "\"count\":2,\"ratio\":0.5,\"none\":null}";
    const root = try parseTest(ar.allocator(), src);
    try testing.expectEqualStrings("ada", root.getT([]const u8, "users[0].name").?);
    try testing.expectEqual(true, root.getT(bool, "users[0].admin").?);
    try testing.expectEqualStrings("bob", root.getT([]const u8, "users[1].name").?);
    try testing.expectEqual(false, root.getT(bool, "users[1].admin").?);
    try testing.expectEqual(@as(i64, 2), root.getT(i64, "count").?);
    try testing.expectEqual(@as(f64, 0.5), root.getT(f64, "ratio").?);
    try testing.expect(root.get("none").? == .null);
    try testing.expectEqual(@as(usize, 2), root.get("users").?.array.len);
}

test "escaped key decodes like a value string" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const root = try parseTest(ar.allocator(), "{\"a\\u0041\": 1}");
    try testing.expectEqual(@as(i64, 1), root.getT(i64, "aA").?);
}

test "structural errors" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.JsonParseError, parseTest(a, "[1,,2]"));
    try testing.expectError(error.JsonParseError, parseTest(a, "{\"a\" 1}"));
    try testing.expectError(error.JsonParseError, parseTest(a, "{1:2}"));
    try testing.expectError(error.JsonParseError, parseTest(a, "]"));
    try testing.expectError(error.JsonParseError, parseTest(a, "}"));
    try testing.expectError(error.JsonParseError, parseTest(a, "[1"));
    try testing.expectError(error.JsonParseError, parseTest(a, "{\"a\":1"));
    try testing.expectError(error.JsonParseError, parseTest(a, ""));
}

test "string content errors" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.JsonParseError, parseTest(a, "\"abc"));
    try testing.expectError(error.JsonParseError, parseTest(a, "\"a\x01b\""));
    try testing.expectError(error.JsonParseError, parseTest(a, "\"a\xffb\""));
    try testing.expectError(error.JsonParseError, parseTest(a, "\"a\x01b\\n\""));
    try testing.expectError(error.JsonParseError, parseTest(a, "\"a\xffb\\n\""));
}

test "surrogate escape errors" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.JsonParseError, parseTest(a, "\"\\udd1e\"")); // lone low
    try testing.expectError(error.JsonParseError, parseTest(a, "\"\\ud834\\u0041\"")); // high + non-surrogate
    try testing.expectError(error.JsonParseError, parseTest(a, "\"\\ud834x\"")); // high + raw byte
    try testing.expectError(error.JsonParseError, parseTest(a, "\"\\u00\"")); // short hex
    try testing.expectError(error.JsonParseError, parseTest(a, "\"\\u00gz\"")); // bad hex digit
}

test "jsonc comments between every token" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const src = "/*a*/{/*b*/\"k\"/*c*/:/*d*/[/*e*/1/*f*/,/*g*/2/*h*/]/*i*/}/*j*/";
    const root = try parse(ar.allocator(), src, .{ .dialect = .jsonc });
    try testing.expectEqual(@as(i64, 1), root.getT(i64, "k[0]").?);
    try testing.expectEqual(@as(i64, 2), root.getT(i64, "k[1]").?);
}

test "lone comma in object is an error in both dialects" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.JsonParseError, parse(a, "{,}", .{}));
    try testing.expectError(error.JsonParseError, parse(a, "{,}", .{ .dialect = .jsonc }));
}

test "jsonc double trailing comma is an error" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.JsonParseError, parse(a, "[1,,]", .{ .dialect = .jsonc }));
    try testing.expectError(error.JsonParseError, parse(a, "{\"a\":1,,}", .{ .dialect = .jsonc }));
}

test "jsonc trailing comma in array" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const root = try parse(ar.allocator(), "[1, 2,]", .{ .dialect = .jsonc });
    try testing.expectEqual(@as(usize, 2), root.array.len);
    try testing.expectEqual(@as(i128, 2), root.array[1].integer);
}

test "duplicate key keeps original insertion position" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const root = try parseTest(ar.allocator(), "{\"a\":1,\"b\":2,\"a\":3}");
    try testing.expectEqual(@as(usize, 2), root.object.count());
    const keys = root.object.keys();
    try testing.expectEqualStrings("a", keys[0]);
    try testing.expectEqualStrings("b", keys[1]);
    try testing.expectEqual(@as(i128, 3), root.object.values()[0].integer);
}

test "number policy: integer range and overflow to float" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Values in i128 range always parse as .integer.
    try testing.expectEqual(@as(i128, -9223372036854775808), (try parseTest(a, "-9223372036854775808")).integer);
    // One below i64 min fits in i128, so it is .integer now.
    try testing.expect((try parseTest(a, "-9223372036854775809")) == .integer);
    // i128 min is still .integer; one below overflows to .float.
    try testing.expect((try parseTest(a, "-170141183460469231731687303715884105728")) == .integer);
    try testing.expect((try parseTest(a, "-170141183460469231731687303715884105729")) == .float);
    // Magnitude beyond f64 max returns inf (RFC 8259 permits inf on overflow).
    const pos_inf = (try parseTest(a, "1e309")).float;
    try testing.expect(std.math.isPositiveInf(pos_inf));
    const neg_inf = (try parseTest(a, "-1e309")).float;
    try testing.expect(std.math.isNegativeInf(neg_inf));
}

test "collects multiple errors in one pass" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const src = "{\"a\": @, \"b\": #, \"c\": 1}";
    const r = parse(a, src, .{ .errors = &errs });
    try std.testing.expectError(error.JsonParseError, r);
    try std.testing.expect(errs.items.len >= 2);
    try std.testing.expect(errs.items[0].span.lineCol(src).line == 1);
}

test "renderRich renders caret line" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const src = "{\"a\": @}";
    _ = parse(a, src, .{ .errors = &errs }) catch {};
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try errs.items[0].renderRich(&aw.writer, src);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "^") != null);
}

test "null errors bails on first error" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectError(error.JsonParseError, parse(ar.allocator(), "[@,@]", .{}));
}

test "recovery inside arrays collects both spans" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    //                   1234567890
    const src = "[@, 2, #, 4]";
    const r = parse(a, src, .{ .errors = &errs });
    try testing.expectError(error.JsonParseError, r);
    try testing.expectEqual(@as(usize, 2), errs.items.len);
    // First diagnostic points at the `@`, second at the `#` -- recovery
    // continued past the first broken element and the clean `2` between.
    try testing.expectEqual(@as(u32, 2), errs.items[0].span.lineCol(src).col);
    try testing.expectEqual(@as(u32, 8), errs.items[1].span.lineCol(src).col);
}

test "nested container recovery does not kill outer parsing" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const r = parse(a, "{\"a\": {\"x\": @}, \"b\": [1, #], \"c\": 3}", .{ .errors = &errs });
    try testing.expectError(error.JsonParseError, r);
    // Exactly two: one per bad token; "c": 3 after both parsed cleanly.
    try testing.expectEqual(@as(usize, 2), errs.items.len);
}

test "recovery skips bracket-balanced and resumes at the right level" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    //                   123456789012345678
    const src = "{\"a\": [1, @, [2, #]], \"b\": 3}";
    const r = parse(a, src, .{ .errors = &errs });
    try testing.expectError(error.JsonParseError, r);
    try testing.expectEqual(@as(usize, 2), errs.items.len);
    try testing.expectEqual(@as(u32, 11), errs.items[0].span.lineCol(src).col);
    try testing.expectEqual(@as(u32, 18), errs.items[1].span.lineCol(src).col);
}

test "MAX_RECOVERY_ERRORS caps diagnostics" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.append(a, '[');
    for (0..150) |i| {
        if (i > 0) try src.append(a, ',');
        try src.append(a, '@');
    }
    try src.append(a, ']');
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const r = parse(a, src.items, .{ .errors = &errs });
    try testing.expectError(error.JsonParseError, r);
    try testing.expectEqual(@as(usize, 100), errs.items.len);
}

test "renderRich clamps the caret at line end on eof error" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const src = "[1,";
    _ = parse(a, src, .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len >= 1);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try errs.items[0].renderRich(&aw.writer, src);
    // The error sits past the last byte; the caret lands one column
    // after the line's end, never beyond.
    try testing.expect(std.mem.indexOf(u8, aw.written(), "[1,\n  |    ^\n") != null);
}

test "renderRich reports line 3 with the correct source line" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const src = "{\n  \"a\": 1,\n  \"b\": @\n}";
    _ = parse(a, src, .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len >= 1);
    try testing.expectEqual(@as(u32, 3), errs.items[0].span.lineCol(src).line);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try errs.items[0].renderRich(&aw.writer, src);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "error at 3:8:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3 |   \"b\": @\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  |        ^\n") != null);
}

test "renderRich: no suggestion renders no did-you-mean" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const src = "[@]";
    _ = parse(a, src, .{ .errors = &errs }) catch {};
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try errs.items[0].renderRich(&aw.writer, src);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "did you mean") == null);
}

test "renderRich: suggestion renders as a help line" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const d = Diagnostic{
        .message = "unknown field `prot`",
        .span = .{ .start = 1, .end = 5 },
        .suggestion = "port",
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try d.renderRich(&aw.writer, "{prot}");
    try testing.expect(std.mem.indexOf(u8, aw.written(), "did you mean `port`?") != null);
}

test "Diagnostic.render one-line rendering" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const src = "[@]";
    _ = parse(a, src, .{ .errors = &errs }) catch {};
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try errs.items[0].render(&aw.writer, src);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "error at 1:2:") != null);
}

test "top-level trailing garbage records one diagnostic and stops" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    try testing.expectError(error.JsonParseError, parse(a, "1 2", .{ .errors = &errs }));
    try testing.expectEqual(@as(usize, 1), errs.items.len);
}

test "nesting depth guard: object branch" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // 129 unclosed object opens must exceed the default depth of 128.
    var buf: [800]u8 = undefined;
    const prefix = "{\"a\":";
    const depth_over = 129;
    var pos: usize = 0;
    for (0..depth_over) |_| {
        @memcpy(buf[pos .. pos + prefix.len], prefix);
        pos += prefix.len;
    }
    try testing.expectError(error.NestingTooDeep, parse(a, buf[0..pos], .{}));

    // Exactly 128 levels with a scalar value inside must succeed.
    const depth_ok = 128;
    pos = 0;
    for (0..depth_ok) |_| {
        @memcpy(buf[pos .. pos + prefix.len], prefix);
        pos += prefix.len;
    }
    buf[pos] = '1';
    pos += 1;
    for (0..depth_ok) |_| {
        buf[pos] = '}';
        pos += 1;
    }
    _ = try parse(a, buf[0..pos], .{});
}

test "error list reused across parses: clean parse succeeds" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    try testing.expectError(error.JsonParseError, parse(a, "[@]", .{ .errors = &errs }));
    try testing.expectEqual(@as(usize, 1), errs.items.len);
    // Same list, clean input: the leftover entry must not fail the parse.
    const ok = try parse(a, "[1, 2]", .{ .errors = &errs });
    try testing.expectEqual(@as(usize, 2), ok.array.len);
    try testing.expectEqual(@as(usize, 1), errs.items.len);
}

test "recovery cap counts only this parse's errors" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    // A list pre-filled past the cap must not disable recovery.
    for (0..MAX_RECOVERY_ERRORS) |_| {
        try errs.append(a, .{ .message = "x", .span = .{ .start = 0, .end = 0 } });
    }
    const r = parse(a, "[@, #, 3]", .{ .errors = &errs });
    try testing.expectError(error.JsonParseError, r);
    try testing.expectEqual(MAX_RECOVERY_ERRORS + 2, errs.items.len);
}

test "depth guard records a diagnostic" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var buf: [129]u8 = undefined;
    @memset(&buf, '[');
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    try testing.expectError(error.NestingTooDeep, parse(a, &buf, .{ .errors = &errs }));
    try testing.expectEqual(@as(usize, 1), errs.items.len);
    try testing.expectEqualStrings("nesting depth exceeds limit (128)", errs.items[0].message);
    // The span points at the bracket that crossed the limit.
    try testing.expectEqual(@as(u32, 129), errs.items[0].span.lineCol(&buf).col);
}

test "comma in array value position terminates the broken region" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    //                   12345678
    const src = "[1,,2,3]";
    const r = parse(a, src, .{ .errors = &errs });
    try testing.expectError(error.JsonParseError, r);
    // One diagnostic for the empty slot; `2` and `3` parse cleanly.
    try testing.expectEqual(@as(usize, 1), errs.items.len);
    try testing.expectEqual(@as(u32, 4), errs.items[0].span.lineCol(src).col);
}

test "comma in object value position keeps the following member" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const src = "{\"a\":,\"b\":2}";
    const r = parse(a, src, .{ .errors = &errs });
    try testing.expectError(error.JsonParseError, r);
    try testing.expectEqual(@as(usize, 1), errs.items.len);
    try testing.expectEqual(@as(u32, 6), errs.items[0].span.lineCol(src).col);
}

test "recovery after an empty slot parses the very next element" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    // The `@` right after the empty slot must be seen (and diagnosed),
    // not swallowed by skipping to the next separator.
    //                   12345678
    const src = "[1,,@,3]";
    const r = parse(a, src, .{ .errors = &errs });
    try testing.expectError(error.JsonParseError, r);
    try testing.expectEqual(@as(usize, 2), errs.items.len);
    try testing.expectEqual(@as(u32, 4), errs.items[0].span.lineCol(src).col);
    try testing.expectEqual(@as(u32, 5), errs.items[1].span.lineCol(src).col);
}

test "strict trailing comma in nested array: one diagnostic, parse continues" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const src = "{\"a\":[1,],\"b\":2}";
    const r = parse(a, src, .{ .errors = &errs });
    try testing.expectError(error.JsonParseError, r);
    // Exactly one diagnostic: recovery closed the array and "b" parsed
    // cleanly (no second error appears).
    try testing.expectEqual(@as(usize, 1), errs.items.len);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "trailing comma") != null);
    try testing.expectEqual(@as(u32, 9), errs.items[0].span.lineCol(src).col);
}

test "spans: container spans run bracket to bracket inclusive" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var spans: Spans = .empty;
    const src = "{\"server\": {\"port\": 8080}, \"tags\": [\"a\", \"b\"]}";
    _ = try parse(ar.allocator(), src, .{ .spans = &spans });
    const server = spans.get("server").?;
    try testing.expectEqualStrings("{\"port\": 8080}", src[server.start..server.end]);
    const tags = spans.get("tags").?;
    try testing.expectEqualStrings("[\"a\", \"b\"]", src[tags.start..tags.end]);
}

test "spans: root value records under the empty path" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    var spans: Spans = .empty;
    const src = "  {\"a\": 1}  ";
    const root = try parse(a, src, .{ .spans = &spans });
    const s = spans.get("").?;
    try testing.expectEqualStrings("{\"a\": 1}", src[s.start..s.end]);
    // `get("")` returns self, so `locate` pairs the root with its span.
    try testing.expect(root.locate(spans, "") != null);

    var scalar_spans: Spans = .empty;
    const scalar_src = "42";
    _ = try parse(a, scalar_src, .{ .spans = &scalar_spans });
    const sc = scalar_spans.get("").?;
    try testing.expectEqualStrings("42", scalar_src[sc.start..sc.end]);
}

test "spans: deep nesting through objects and arrays" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var spans: Spans = .empty;
    const src = "{\"a\": {\"b\": {\"c\": [{\"d\": 5}]}}}";
    _ = try parse(ar.allocator(), src, .{ .spans = &spans });
    const d = spans.get("a.b.c[0].d").?;
    try testing.expectEqualStrings("5", src[d.start..d.end]);
    const c0 = spans.get("a.b.c[0]").?;
    try testing.expectEqualStrings("{\"d\": 5}", src[c0.start..c0.end]);
}

test "spans: chained array indices" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var spans: Spans = .empty;
    const src = "{\"m\": [[0], [1, 2, 3]]}";
    _ = try parse(ar.allocator(), src, .{ .spans = &spans });
    const e = spans.get("m[1][2]").?;
    try testing.expectEqualStrings("3", src[e.start..e.end]);
    const row = spans.get("m[1]").?;
    try testing.expectEqualStrings("[1, 2, 3]", src[row.start..row.end]);
}

test "spans: duplicate key records the last occurrence" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var spans: Spans = .empty;
    const src = "{\"a\": 1, \"a\": 22}";
    const root = try parse(ar.allocator(), src, .{ .spans = &spans });
    try testing.expectEqual(@as(i64, 22), root.getT(i64, "a").?);
    const s = spans.get("a").?;
    try testing.expectEqualStrings("22", src[s.start..s.end]);
}

test "spans: jsonc comments do not corrupt spans" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var spans: Spans = .empty;
    const src = "{ /*x*/ \"k\" /*x*/ : /*x*/ [ /*x*/ 1 /*x*/ , 2 ] /*x*/ }";
    _ = try parse(ar.allocator(), src, .{ .dialect = .jsonc, .spans = &spans });
    const e0 = spans.get("k[0]").?;
    try testing.expectEqualStrings("1", src[e0.start..e0.end]);
    const k = spans.get("k").?;
    try testing.expectEqualStrings("[ /*x*/ 1 /*x*/ , 2 ]", src[k.start..k.end]);
}

test "spans: empty containers" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var spans: Spans = .empty;
    const src = "{\"e\": {}, \"f\": []}";
    _ = try parse(ar.allocator(), src, .{ .spans = &spans });
    const e = spans.get("e").?;
    try testing.expectEqualStrings("{}", src[e.start..e.end]);
    const f = spans.get("f").?;
    try testing.expectEqualStrings("[]", src[f.start..f.end]);
}

test "spans with error recovery: clean values recorded, broken ones skipped" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    var spans: Spans = .empty;
    const src = "{\"a\": @, \"b\": 2, \"c\": [1, #, 3]}";
    const r = parse(a, src, .{ .errors = &errs, .spans = &spans });
    try testing.expectError(error.JsonParseError, r);
    try testing.expectEqual(@as(usize, 2), errs.items.len);
    // The recovered `.null` substitutes record nothing.
    try testing.expect(spans.get("a") == null);
    try testing.expect(spans.get("c[1]") == null);
    // Cleanly-parsed values in the same pass still record.
    const b = spans.get("b").?;
    try testing.expectEqualStrings("2", src[b.start..b.end]);
    const c0 = spans.get("c[0]").?;
    try testing.expectEqualStrings("1", src[c0.start..c0.end]);
    const c2 = spans.get("c[2]").?;
    try testing.expectEqualStrings("3", src[c2.start..c2.end]);
}

test "jsonc recovery with interleaved comments keeps correct cols" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    //                          12345678901234567 8 (then line 2: " #]")
    const src = "[/*a*/ @, 2, // b\n #]";
    const r = parse(a, src, .{ .dialect = .jsonc, .errors = &errs });
    try testing.expectError(error.JsonParseError, r);
    try testing.expectEqual(@as(usize, 2), errs.items.len);
    try testing.expectEqual(@as(u32, 1), errs.items[0].span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 8), errs.items[0].span.lineCol(src).col);
    try testing.expectEqual(@as(u32, 2), errs.items[1].span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 2), errs.items[1].span.lineCol(src).col);
}

test "spans map: offsets past 4 GiB record exactly with u64 (boundary injected)" {
    // u64 span offsets address any in-memory input without a cap. recordSpan
    // must store an offset past maxInt(u32) exactly, not truncate or reject.
    // Inject the boundary via a synthetic RawToken so no 4 GiB buffer is
    // allocated.
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var spans: Spans = .empty;
    var p = Parser{
        .arena = ar.allocator(),
        .input = "x",
        .tokenizer = .init("x", .json),
        .options = .{ .spans = &spans },
    };
    const over: usize = @as(usize, std.math.maxInt(u32)) + 1;
    const start: RawToken = .{ .kind = .number, .start = over, .end = over };
    try p.recordSpan(start, over + 5);
    const s = spans.get("").?;
    try testing.expectEqual(@as(u64, over), s.start);
    try testing.expectEqual(@as(u64, over + 5), s.end);
}

test "tokenizer: nextRaw carries exact usize offsets; line/col derived via lineCol" {
    // The internal token offsets must match a plain parse's slicing; this
    // proves the usize-internal tokenizer keeps spans correct for normal
    // inputs (the >4 GiB plain-parse hot path uses these exact offsets).
    const src = "{\n  \"k\": 1234\n}";
    var tz = tokenizer_mod.Tokenizer.init(src, .json);
    const open = tz.nextRaw().?;
    try testing.expectEqual(tokenizer_mod.Kind.object_begin, open.kind);
    try testing.expectEqual(@as(usize, 0), open.start);
    const key = tz.nextRaw().?;
    try testing.expectEqual(tokenizer_mod.Kind.string, key.kind);
    try testing.expectEqualStrings("\"k\"", src[key.start..key.end]);
    const key_span: v.Span = .{ .start = key.start, .end = key.end };
    try testing.expectEqual(@as(u32, 2), key_span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 3), key_span.lineCol(src).col);
    _ = tz.nextRaw().?; // colon
    const num = tz.nextRaw().?;
    try testing.expectEqualStrings("1234", src[num.start..num.end]);
}
