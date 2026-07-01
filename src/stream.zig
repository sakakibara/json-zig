const std = @import("std");
const lex = @import("lex.zig");
const value = @import("value.zig");
const parser = @import("parser.zig");
const tokenizer = @import("tokenizer.zig");

pub const Span = value.Span;
pub const Value = value.Value;
pub const Diagnostic = parser.Diagnostic;
pub const NumberMode = parser.NumberMode;
pub const Dialect = tokenizer.Dialect;

const testing = std.testing;

/// Coerce a streaming `number` event's raw lexeme to i128. Returns null for
/// float-syntax lexemes (containing `.`, `e`, or `E`) and for values that
/// cannot be represented in i128. For values outside the i128 range, parse
/// the raw lexeme directly with `std.fmt.parseInt` using the desired wider type.
pub fn asInt(number_bytes: []const u8) ?i128 {
    return std.fmt.parseInt(i128, number_bytes, 10) catch null;
}

pub fn asFloat(number_bytes: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, number_bytes) catch null;
}

test "empty input yields end_of_input then null" {
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("   \n\t ");
    er.endInput();
    const ev = (try er.next()).?;
    try testing.expectEqual(Event.Kind.end_of_input, std.meta.activeTag(ev.kind));
    try testing.expectEqual(@as(?Event, null), try er.next());
}

pub const Event = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        object_begin,
        object_end,
        array_begin,
        array_end,
        object_key: []const u8,
        string: []const u8,
        number: []const u8,
        boolean: bool,
        null,
        end_of_input,
    };
};

pub const StreamShape = enum {
    // The stream is a single top-level JSON array; each next() yields one element.
    array_elements,
    // The stream contains one or more whitespace/newline-separated top-level values.
    multi_document,
    // Resolve on the first event: array_begin -> array_elements, else multi_document.
    auto,
};

pub const StreamOptions = struct {
    dialect: Dialect = .json,
    number_mode: NumberMode = .typed,
    max_depth: usize = 128,
    max_token_len: usize = 16 * 1024 * 1024,
    errors: ?*std.ArrayList(Diagnostic) = null,
    shape: StreamShape = .auto,
};

// Streaming is unbounded: events keep flowing past 4 GiB of total input in
// bounded memory (the sliding window compacts each next()). Event DATA
// (keys, string/number lexemes, kinds) is always correct. Event.span fields
// (start, end) are u64 absolute byte offsets, so they address any input
// without a cap; derive line/col on demand with `Span.lineCol`.

pub const StreamError = error{
    JsonParseError,
    NestingTooDeep,
    TokenTooLong,
    NeedMoreInput,
    UnexpectedEndOfInput,
} || std.mem.Allocator.Error || std.Io.Reader.LimitedAllocError;

// Per-frame container state for the explicit (non-recursive) parse stack.
const Frame = struct {
    is_object: bool,
    // What the next token must be within this container.
    expect: enum { first_item, comma_or_close, key, colon, value },
};

pub const EventReader = struct {
    gpa: std.mem.Allocator,
    options: StreamOptions,
    buf: std.ArrayList(u8) = .empty,      // unconsumed bytes (sliding window)
    base: u64 = 0,                         // absolute stream offset of buf.items[0]
    pos: usize = 0,                        // cursor within buf
    stack: std.ArrayList(Frame) = .empty,  // container nesting; len bounded by max_depth
    top_done: bool = false,                // a complete top-level value has been emitted
    allow_multi: bool = false,             // when true, reset top_done instead of erroring on second top-level value
    ended: bool = false,                   // endInput()/EOF observed
    closed: bool = false,                  // end_of_input already returned
    reader: ?*std.Io.Reader = null,
    scratch: std.ArrayList(u8) = .empty,   // assembled boundary token / decoded string
    diag: ?Diagnostic = null,
    last: ?Event = null,                   // most recent event returned by next()
    /// A materialize() suspended by error.NeedMoreInput: the partially
    /// built container stack, resumed by the next materialize() call.
    /// Partial values live in the arena of the suspended call, so the
    /// caller must resume with the SAME arena (and must not reset it
    /// until a value is returned).
    mat: ?std.ArrayList(MaterializeFrame) = null,

    pub fn init(gpa: std.mem.Allocator, options: StreamOptions) EventReader {
        return .{ .gpa = gpa, .options = options };
    }

    pub fn deinit(self: *EventReader) void {
        self.buf.deinit(self.gpa);
        self.stack.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        // A suspended materialize's frame lists are caller-arena-owned;
        // only the stack itself is gpa-allocated.
        if (self.mat) |*m| m.deinit(self.gpa);
    }

    /// Append input bytes. Like next(), feed() INVALIDATES borrowed event
    /// payloads: the append can grow and move the internal buffer they point
    /// into. `last` is cleared so a stale materialize() fails loudly instead
    /// of reading moved memory; a suspended materialize (error.NeedMoreInput)
    /// is unaffected -- its partial value lives in the caller's arena.
    pub fn feed(self: *EventReader, bytes: []const u8) std.mem.Allocator.Error!void {
        try self.buf.appendSlice(self.gpa, bytes);
        self.last = null;
    }

    /// Signal that no more bytes will be fed. Infallible: it only sets a
    /// flag; any truncation error surfaces from the following next() call.
    pub fn endInput(self: *EventReader) void {
        self.ended = true;
    }

    pub fn fromReader(gpa: std.mem.Allocator, reader: *std.Io.Reader, options: StreamOptions) EventReader {
        var er = EventReader.init(gpa, options);
        er.reader = reader;
        return er;
    }

    // Pull one chunk from the backing reader into buf.
    fn pull(self: *EventReader) StreamError!void {
        var tmp: [4096]u8 = undefined;
        const n = try self.reader.?.readSliceShort(&tmp);
        if (n == 0) {
            self.ended = true;
            return;
        }
        try self.buf.appendSlice(self.gpa, tmp[0..n]);
    }

    /// Advance to the next event. Returns null when the stream is exhausted
    /// (after the closing `end_of_input` event has been returned once).
    ///
    /// Empty / whitespace-only input: `EventReader` treats a stream with no
    /// JSON value as valid -- `next()` returns an `end_of_input` event (not
    /// an error). This differs from `json.parse`, which rejects empty input
    /// with `error.JsonParseError` per RFC 8259 (a JSON text must be a value).
    /// Callers that need single-document semantics should check for a leading
    /// `end_of_input` and treat it as an error.
    pub fn next(self: *EventReader) StreamError!?Event {
        // Reclaim the consumed prefix lazily (see maybeCompact). Slices from the
        // last returned event borrow buf and may be shifted here, but the borrow
        // contract guarantees callers don't hold them across next().
        self.maybeCompact();
        // No 4-GiB cap: absOffset() is a u64 absolute offset, so streaming
        // continues past 4 GiB in bounded memory with correct event data.
        const ev = if (self.reader == null) try self.nextInner() else blk: {
            // Reader-backed path: retry after pulling more bytes on NeedMoreInput.
            while (true) {
                break :blk self.nextInner() catch |e| switch (e) {
                    error.NeedMoreInput => {
                        try self.pull();
                        continue;
                    },
                    else => return e,
                };
            }
        };
        self.last = ev;
        return ev;
    }

    fn nextInner(self: *EventReader) StreamError!?Event {
        if (self.closed) return null;

        try self.skipInsignificant();

        // Buffer exhausted: either need more input or we are done.
        if (self.pos >= self.buf.items.len) {
            if (!self.ended) return error.NeedMoreInput;
            if (self.stack.items.len != 0) return self.failEof();
            self.closed = true;
            return self.makeZeroSpan(.end_of_input);
        }

        const tok_start = self.absOffset();
        const ch = self.buf.items[self.pos];

        // Top-level (no open container): only one value is allowed unless allow_multi.
        if (self.stack.items.len == 0) {
            if (self.top_done) {
                if (self.allow_multi) {
                    // Multi-document mode: accept another top-level value.
                    self.top_done = false;
                } else {
                    // A second top-level value is a parse error in single-document mode.
                    return self.fail("unexpected character after top-level value", self.spanFrom(tok_start));
                }
            }
            const ev = try self.scanValue(tok_start);
            // Scalars finish the top-level immediately; containers set top_done on
            // their matching close event (handled below).
            if (self.stack.items.len == 0) self.top_done = true;
            return ev;
        }

        // Inside a container: dispatch by the current frame's expected token.
        // Use an index rather than a pointer: scanValue may call pushFrame which
        // appends to the stack ArrayList and would invalidate a held pointer.
        const frame_idx = self.stack.items.len - 1;
        const is_object = self.stack.items[frame_idx].is_object;
        const expect = self.stack.items[frame_idx].expect;
        if (is_object) {
            switch (expect) {
                .first_item => {
                    if (ch == '}') {
                        self.advance();
                        return self.closeContainer(tok_start);
                    }
                    // Expect a string key.
                    if (ch != '"') return self.fail("expected object key or '}'", self.spanFrom(tok_start));
                    const ev = try self.scanString(tok_start);
                    self.stack.items[frame_idx].expect = .colon;
                    return .{ .kind = .{ .object_key = ev.kind.string }, .span = ev.span };
                },
                .comma_or_close => {
                    if (ch == '}') {
                        self.advance();
                        return self.closeContainer(tok_start);
                    }
                    if (ch != ',') return self.fail("expected ',' or '}'", self.spanFrom(tok_start));
                    self.advance();
                    self.stack.items[frame_idx].expect = .key;
                    return self.nextInner();
                },
                .key => {
                    // Trailing comma under jsonc: `{...,}` is accepted.
                    if (ch == '}' and self.options.dialect == .jsonc) {
                        self.advance();
                        return self.closeContainer(tok_start);
                    }
                    if (ch != '"') return self.fail("expected object key", self.spanFrom(tok_start));
                    const ev = try self.scanString(tok_start);
                    self.stack.items[frame_idx].expect = .colon;
                    return .{ .kind = .{ .object_key = ev.kind.string }, .span = ev.span };
                },
                .colon => {
                    if (ch != ':') return self.fail("expected ':'", self.spanFrom(tok_start));
                    self.advance();
                    self.stack.items[frame_idx].expect = .value;
                    return self.nextInner();
                },
                .value => {
                    const ev = try self.scanValue(tok_start);
                    // If scanValue pushed a new frame (container value), the parent
                    // frame's expect is updated on the container's close event instead.
                    if (self.stack.items.len == frame_idx + 1) {
                        self.stack.items[frame_idx].expect = .comma_or_close;
                    }
                    return ev;
                },
            }
        } else {
            // Array frame.
            switch (expect) {
                .first_item => {
                    if (ch == ']') {
                        self.advance();
                        return self.closeContainer(tok_start);
                    }
                    const ev = try self.scanValue(tok_start);
                    if (self.stack.items.len == frame_idx + 1) {
                        self.stack.items[frame_idx].expect = .comma_or_close;
                    }
                    return ev;
                },
                .comma_or_close => {
                    if (ch == ']') {
                        self.advance();
                        return self.closeContainer(tok_start);
                    }
                    if (ch != ',') return self.fail("expected ',' or ']'", self.spanFrom(tok_start));
                    self.advance();
                    self.stack.items[frame_idx].expect = .value;
                    return self.nextInner();
                },
                .value => {
                    // Trailing comma under jsonc: `[...,]` is accepted.
                    if (ch == ']' and self.options.dialect == .jsonc) {
                        self.advance();
                        return self.closeContainer(tok_start);
                    }
                    const ev = try self.scanValue(tok_start);
                    if (self.stack.items.len == frame_idx + 1) {
                        self.stack.items[frame_idx].expect = .comma_or_close;
                    }
                    return ev;
                },
                // These states are object-only; arrays never reach them.
                .key, .colon => unreachable,
            }
        }
    }

    // Pop the current frame and emit the matching end event. When the stack
    // empties, marks top_done so the document is complete.
    fn closeContainer(self: *EventReader, start: u64) Event {
        const was_object = self.stack.pop().?.is_object;
        if (self.stack.items.len == 0) self.top_done = true;
        // If there is a parent frame, its value slot is now filled.
        if (self.stack.items.len > 0) {
            self.stack.items[self.stack.items.len - 1].expect = .comma_or_close;
        }
        const kind: Event.Kind = if (was_object) .object_end else .array_end;
        return .{ .kind = kind, .span = self.spanFrom(start) };
    }

    // Dispatch on the current byte as a JSON value start. Handles scalars plus
    // '{' and '[' which push a new frame and emit the corresponding begin event.
    fn scanValue(self: *EventReader, start: u64) StreamError!Event {
        switch (self.buf.items[self.pos]) {
            '{' => {
                self.advance();
                try self.pushFrame(true);
                return .{ .kind = .object_begin, .span = self.spanFrom(start) };
            },
            '[' => {
                self.advance();
                try self.pushFrame(false);
                return .{ .kind = .array_begin, .span = self.spanFrom(start) };
            },
            'n' => return self.scanKeyword("null", .null, start),
            't' => return self.scanKeyword("true", .{ .boolean = true }, start),
            'f' => return self.scanKeyword("false", .{ .boolean = false }, start),
            '"' => return self.scanString(start),
            '-', '0'...'9' => return self.scanNumber(start),
            else => return self.fail("unexpected character", self.spanFrom(start)),
        }
    }

    // Push a new container frame. Checks depth BEFORE appending so the guard
    // fires before any allocation, keeping next() iterative with no host recursion.
    fn pushFrame(self: *EventReader, is_object: bool) StreamError!void {
        if (self.stack.items.len >= self.options.max_depth) return error.NestingTooDeep;
        try self.stack.append(self.gpa, .{ .is_object = is_object, .expect = .first_item });
    }

    // Skip whitespace and (in .jsonc dialect) comments. Returns NeedMoreInput if
    // a block comment starts but the closing `*/` is not yet in the buffer.
    // Atomicity: for block comments, the cursor is NOT advanced past the opening
    // `/*` unless the full `*/` terminator is found in the current buffer. This
    // mirrors the scalar scanners' discipline so chunk-boundary resumption works
    // correctly -- re-running after more bytes re-scans from the same `/`.
    // Line comments scan ahead for '\n' before advancing, same as block comments
    // scan ahead for '*/'. Both resume correctly from the '/' when NeedMoreInput
    // is returned: compact() leaves pos at the '/' so the next call re-scans.
    fn skipInsignificant(self: *EventReader) StreamError!void {
        const items = self.buf.items;
        outer: while (self.pos < items.len) {
            switch (items[self.pos]) {
                ' ', '\t', '\n', '\r' => self.advance(),
                '/' => {
                    if (self.options.dialect != .jsonc) {
                        // A bare `/` is always a parse error in strict JSON.
                        const off = self.absOffset();
                        return self.fail("unexpected '/'", self.spanFrom(off));
                    }
                    // Need at least one more byte to know comment kind.
                    if (self.pos + 1 >= items.len) {
                        if (!self.ended) return error.NeedMoreInput;
                        // `/` at EOF with no following byte: parse error (bare `/`).
                        const off = self.absOffset();
                        return self.fail("unexpected '/'", self.spanFrom(off));
                    }
                    switch (items[self.pos + 1]) {
                        '/' => {
                            // Line comment: scan ahead for '\n' without advancing, so a
                            // boundary inside the comment body is recoverable.  If '\n'
                            // is not in the current buffer and more bytes may arrive,
                            // leave the cursor at '/' and ask for more data.
                            var j = self.pos + 2;
                            while (j < items.len and items[j] != '\n') : (j += 1) {}
                            const found_nl = j < items.len; // items[j] == '\n'
                            if (!found_nl) {
                                if (!self.ended) return error.NeedMoreInput;
                                // End of input inside a line comment: the comment
                                // is complete (no '\n' needed at EOF).
                                // Advance through the rest and let the outer loop
                                // exit on the next iteration.
                                self.advance(); // `/`
                                self.advance(); // `/`
                                while (self.pos < items.len) self.advance();
                            } else {
                                // Full comment line is in buffer: advance through it.
                                self.advance(); // `/`
                                self.advance(); // `/`
                                while (self.pos < items.len and items[self.pos] != '\n') {
                                    self.advance();
                                }
                            }
                        },
                        '*' => {
                            // Block comment: must find `*/` in the buffer before advancing.
                            // Scan ahead without touching pos/line/col.
                            var j = self.pos + 2;
                            const found = blk: {
                                while (j + 1 < items.len) {
                                    if (items[j] == '*' and items[j + 1] == '/') break :blk true;
                                    j += 1;
                                }
                                break :blk false;
                            };
                            if (!found) {
                                if (!self.ended) return error.NeedMoreInput;
                                // Unterminated block comment at end of input.
                                const off = self.absOffset();
                                return self.fail("unterminated block comment", self.spanFrom(off));
                            }
                            // Full comment is in buffer: advance through `/*`, body, `*/`.
                            self.advance(); // `/`
                            self.advance(); // `*`
                            while (!(items[self.pos] == '*' and items[self.pos + 1] == '/')) {
                                self.advance();
                            }
                            self.advance(); // `*`
                            self.advance(); // `/`
                        },
                        else => {
                            // `/` followed by something other than `/` or `*`.
                            const off = self.absOffset();
                            return self.fail("unexpected '/'", self.spanFrom(off));
                        },
                    }
                },
                else => break :outer,
            }
        }
    }

    fn advance(self: *EventReader) void {
        self.pos += 1;
    }

    // Absolute stream offset of the cursor. u64, so streaming addresses any
    // input without a 4 GiB cap; line/col are derived on demand from the span.
    fn absOffset(self: *const EventReader) u64 {
        return self.base + self.pos;
    }

    fn makeZeroSpan(self: *const EventReader, kind: Event.Kind) Event {
        const off = self.absOffset();
        return .{ .kind = kind, .span = .{ .start = off, .end = off } };
    }

    fn failEof(self: *EventReader) StreamError {
        self.diag = .{ .message = "unexpected end of input", .span = self.makeZeroSpan(.end_of_input).span, .suggestion = null };
        return error.UnexpectedEndOfInput;
    }

    pub fn diagnostic(self: *const EventReader) ?Diagnostic {
        return self.diag;
    }

    fn spanFrom(self: *const EventReader, start: u64) Span {
        return .{ .start = start, .end = self.absOffset() };
    }

    fn fail(self: *EventReader, msg: []const u8, span: Span) StreamError {
        self.diag = .{ .message = msg, .span = span, .suggestion = null };
        // The diagnostics sink is best-effort: on OOM the entry is dropped
        // rather than masking the parse error with error.OutOfMemory.
        if (self.options.errors) |sink| sink.append(self.gpa, self.diag.?) catch {};
        return error.JsonParseError;
    }

    fn remaining(self: *const EventReader) []const u8 {
        return self.buf.items[self.pos..];
    }

    // Compact only once the consumed prefix reaches half the buffer. Shifting on
    // every next() is Theta(N) per token and Theta(N^2) over a whole-fed input;
    // gating on pos >= buf.len/2 makes the cost amortized O(1) per byte (each
    // byte is shifted at most O(log N) times as the live window halves), so a
    // whole-fed N-byte document drains in O(N). Memory stays bounded: the live
    // window is never larger than the in-flight token plus buffered-ahead data,
    // and compaction caps the dead prefix at half the buffer, so capacity holds
    // at O(max_token_len + chunk) on the reader-backed path.
    fn maybeCompact(self: *EventReader) void {
        if (self.pos == 0) return;
        if (self.pos * 2 < self.buf.items.len) return;
        self.compact();
    }

    // Drop bytes before the current cursor so steady-state buffer memory is
    // bounded to the current in-flight token plus any buffered-ahead data.
    // Safe to call at any point: the pos==0 guard makes it a no-op when
    // nothing has been consumed (e.g. on the NeedMoreInput path). Span offsets
    // remain valid because they are stored as absOffset() values (base + pos),
    // and we adjust base to compensate for the shift.
    fn compact(self: *EventReader) void {
        if (self.pos == 0) return;
        const keep = self.buf.items.len - self.pos;
        std.mem.copyForwards(u8, self.buf.items[0..keep], self.buf.items[self.pos..]);
        self.buf.shrinkRetainingCapacity(keep);
        self.base += self.pos;
        self.pos = 0;
    }

    fn isIdentByte(c: u8) bool {
        return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
    }

    fn scanKeyword(self: *EventReader, word: []const u8, kind: Event.Kind, start: u64) StreamError!Event {
        const rem = self.remaining();
        if (rem.len < word.len) {
            if (!self.ended) return error.NeedMoreInput;
            // Fewer bytes than the keyword and end-of-input: the token was truncated.
            self.diag = .{ .message = "unexpected end of input", .span = self.spanFrom(start), .suggestion = null };
            return error.UnexpectedEndOfInput;
        }
        if (!std.mem.eql(u8, rem[0..word.len], word)) return self.fail("invalid literal", self.spanFrom(start));
        // Reject trailing identifier bytes (e.g. "truex").
        if (rem.len > word.len and isIdentByte(rem[word.len])) {
            return self.fail("invalid literal", self.spanFrom(start));
        }
        // Keyword exactly fills the buffer and we haven't seen end-of-input: the
        // next chunk could continue with an identifier byte (e.g. "tru" + "ex").
        // Wait for one more byte so we can check.
        if (rem.len == word.len and !self.ended) return error.NeedMoreInput;
        var i: usize = 0;
        while (i < word.len) : (i += 1) self.advance();
        return .{ .kind = kind, .span = self.spanFrom(start) };
    }

    fn scanNumber(self: *EventReader, start: u64) StreamError!Event {
        var i: usize = self.pos;
        const items = self.buf.items;
        while (i < items.len and lex.classifyNumberByte(items[i]) != .other) : (i += 1) {
            if (i - self.pos > self.options.max_token_len) return error.TokenTooLong;
        }
        // If the lexeme reaches the buffer end and more bytes may follow, the
        // number could continue; wait for more data or end-of-input.
        if (i >= items.len and !self.ended) return error.NeedMoreInput;
        const lexeme = items[self.pos..i];
        // Final length check: the mid-loop guard uses > so a number of exactly
        // max_token_len+1 bytes would slip through without this post-loop check.
        if (lexeme.len > self.options.max_token_len) return error.TokenTooLong;
        if (!lex.isValidNumber(lexeme)) {
            // Distinguish truncation from structural corruption: if the scan
            // stopped at buffer end (not at a delimiter byte) and we are at
            // end-of-input, the number fragment was cut off by EOF rather than
            // followed by a bad byte. A valid number at buffer end is accepted
            // above; only invalid-at-EOF fragments land here.
            if (i >= items.len and self.ended) {
                self.diag = .{ .message = "unexpected end of input", .span = self.spanFrom(start), .suggestion = null };
                return error.UnexpectedEndOfInput;
            }
            return self.fail("invalid number", self.spanFrom(start));
        }
        while (self.pos < i) self.advance();
        return .{ .kind = .{ .number = lexeme }, .span = self.spanFrom(start) };
    }

    fn scanString(self: *EventReader, start: u64) StreamError!Event {
        // self.buf.items[self.pos] == '"'
        const body_start = self.pos + 1;
        var i = body_start;
        const items = self.buf.items;
        var has_escape = false;
        while (true) {
            const skipped = lex.scanStringFast(items[i..]);
            i += skipped;
            // Fail fast if the in-progress body already exceeds the limit.
            if (i - body_start > self.options.max_token_len) return error.TokenTooLong;
            if (i >= items.len) {
                if (!self.ended) return error.NeedMoreInput;
                // Buffer exhausted mid-string with end-of-input: the token was
                // truncated by EOF, not corrupted.
                self.diag = .{ .message = "unexpected end of input", .span = self.spanFrom(start), .suggestion = null };
                return error.UnexpectedEndOfInput;
            }
            switch (items[i]) {
                '"' => break,
                '\\' => {
                    has_escape = true;
                    // Need the escape byte (and possibly 4 hex) present.
                    if (i + 1 >= items.len) {
                        if (!self.ended) return error.NeedMoreInput;
                        // Backslash at end of buffer with end-of-input: truncated.
                        self.diag = .{ .message = "unexpected end of input", .span = self.spanFrom(start), .suggestion = null };
                        return error.UnexpectedEndOfInput;
                    }
                    i += 2; // skip backslash + escaped byte; \u handled in decode pass
                },
                else => return self.fail("control character in string", self.spanFrom(start)),
            }
        }
        const raw = items[body_start..i]; // between the quotes, may contain escapes
        if (raw.len > self.options.max_token_len) return error.TokenTooLong;
        const span = self.spanFrom(start);
        const decoded = if (has_escape) try self.decodeInto(raw, span) else blk: {
            // No escape sequences: the scanner accepted all non-quote,
            // non-backslash, non-control bytes -- but that includes raw bytes
            // >= 0x80 that may form invalid UTF-8. Validate here to match the
            // tree parser's strict policy (parser.validateRaw rejects bad UTF-8).
            if (!std.unicode.utf8ValidateSlice(raw)) return self.fail("invalid utf-8 in string", span);
            break :blk raw;
        };
        // advance cursor past the closing quote
        while (self.pos <= i) self.advance();
        return .{ .kind = .{ .string = decoded }, .span = self.spanFrom(start) };
    }

    // Decode JSON string escapes from `raw` into self.scratch; returns the
    // decoded slice (valid until the next next()). Shares lex.unescape with
    // the tree parser, so escape rules (including surrogate-pair combination)
    // are identical; only the diagnostic messages are stream-specific.
    fn decodeInto(self: *EventReader, raw: []const u8, span: Span) StreamError![]const u8 {
        self.scratch.clearRetainingCapacity();
        lex.unescape(true, self.gpa, raw, &self.scratch) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TruncatedEscape, error.InvalidEscape => self.fail("bad escape", span),
            error.InvalidCodepoint => self.fail("bad codepoint", span),
            error.TruncatedUnicodeEscape => self.fail("truncated \\u escape", span),
            error.InvalidHexDigit => self.fail("invalid hex digit in \\u escape", span),
            error.LoneLowSurrogate => self.fail("lone low surrogate in \\u escape", span),
            error.UnpairedHighSurrogate => self.fail("unpaired high surrogate in \\u escape", span),
            error.ControlCharacter => self.fail("control character in string", span),
            error.InvalidUtf8 => self.fail("invalid utf-8 in string", span),
        };
        return self.scratch.items;
    }

    // Build a Value from the most recent event returned by next(). The value
    // and all its strings/arrays/objects are allocated in arena. After return,
    // the reader is positioned just past the materialized value.
    //
    // Precondition: next() was just called and returned a value-starting event
    // (object_begin, array_begin, or a scalar). Returns error.JsonParseError if
    // the most recent event is not a value start (e.g. object_key, *_end, or
    // end_of_input).
    pub fn materialize(self: *EventReader, arena: std.mem.Allocator) StreamError!Value {
        // Resume a materialize suspended by error.NeedMoreInput. The caller
        // must pass the same arena as the suspended call.
        if (self.mat) |stack| {
            self.mat = null;
            var st = stack;
            return self.materializeLoop(arena, &st);
        }
        const ev = self.last orelse return error.JsonParseError;
        return switch (ev.kind) {
            .null => .null,
            .boolean => |b| .{ .bool = b },
            .string => |s| .{ .string = try arena.dupe(u8, s) },
            .number => |n| try self.numberValue(arena, n),
            .object_begin, .array_begin => try self.materializeContainer(arena, ev.kind),
            // object_key, *_end, end_of_input: not at a value-starting position.
            else => error.JsonParseError,
        };
    }

    // Coerce a number lexeme to a Value honoring number_mode. Integer-syntax
    // lexemes become .integer (i128 range; overflow falls back to .float),
    // matching the tree parser's typed-mode policy.
    fn numberValue(self: *EventReader, arena: std.mem.Allocator, lexeme: []const u8) StreamError!Value {
        if (self.options.number_mode == .raw) return .{ .number_raw = try arena.dupe(u8, lexeme) };
        if (std.mem.indexOfAny(u8, lexeme, ".eE") == null) {
            // The lexer pre-validates number syntax, so a non-float lexeme is
            // guaranteed to be [-][0-9]+. InvalidCharacter is unreachable here;
            // Overflow means the value exceeds i128 and falls through to float.
            if (std.fmt.parseInt(i128, lexeme, 10)) |i|
                return .{ .integer = i }
            else |err| switch (err) {
                error.Overflow => {},
                error.InvalidCharacter => unreachable,
            }
        }
        return .{ .float = asFloat(lexeme) orelse return error.JsonParseError };
    }

    // In-progress container frame for the explicit materialize stack.
    const MaterializeFrame = union(enum) {
        array: std.ArrayList(Value),
        // pending_key is set when the last event was object_key; null when
        // waiting for the next key.
        object: struct { map: value.ObjectMap, pending_key: ?[]const u8 },
    };

    // Consume events from the reader to build the container value that was
    // opened by `start_kind` (object_begin or array_begin). Uses an explicit
    // stack of in-progress frames to avoid host-stack recursion on deeply nested
    // input -- each begin event pushes a new frame, each end event pops and
    // attaches the completed child to the parent frame above it.
    fn materializeContainer(self: *EventReader, arena: std.mem.Allocator, start_kind: Event.Kind) StreamError!Value {
        var stack: std.ArrayList(MaterializeFrame) = .empty;
        // Push the root frame corresponding to the already-consumed begin event.
        switch (start_kind) {
            .object_begin => try stack.append(self.gpa, .{ .object = .{ .map = .empty, .pending_key = null } }),
            .array_begin => try stack.append(self.gpa, .{ .array = .empty }),
            else => unreachable,
        }
        return self.materializeLoop(arena, &stack);
    }

    /// Drop a materialize frame stack: array-frame lists are returned to the
    /// caller's arena; object maps are arena-allocated and reclaimed in bulk.
    fn dropMatStack(self: *EventReader, arena: std.mem.Allocator, stack: *std.ArrayList(MaterializeFrame)) void {
        for (stack.items) |*frame| {
            switch (frame.*) {
                .array => |*lst| lst.deinit(arena),
                .object => {},
            }
        }
        stack.deinit(self.gpa);
    }

    /// The materialize event loop over an explicit frame stack. On
    /// error.NeedMoreInput the stack is SUSPENDED into `self.mat` (partial
    /// values stay valid in `arena`) so a later materialize() resumes the
    /// same record instead of re-entering the event stream mid-record;
    /// every other exit path drops the stack.
    fn materializeLoop(self: *EventReader, arena: std.mem.Allocator, stack: *std.ArrayList(MaterializeFrame)) StreamError!Value {
        // Covers every error exit; the suspend path empties the stack first,
        // so dropping the residue is a no-op there.
        errdefer self.dropMatStack(arena, stack);
        while (stack.items.len > 0) {
            const ev = (self.next() catch |e| {
                if (e == error.NeedMoreInput) {
                    self.mat = stack.*;
                    stack.* = .empty;
                }
                return e;
            }) orelse return error.JsonParseError;
            const top_idx = stack.items.len - 1;

            switch (ev.kind) {
                .object_begin => {
                    // Child object opened: push a new object frame.
                    try stack.append(self.gpa, .{ .object = .{ .map = .empty, .pending_key = null } });
                },
                .array_begin => {
                    // Child array opened: push a new array frame.
                    try stack.append(self.gpa, .{ .array = .empty });
                },
                .object_end => {
                    // Close the top object frame and attach the completed Value to its parent.
                    const frame = stack.pop().?;
                    const completed = Value{ .object = frame.object.map };
                    if (stack.items.len == 0) {
                        stack.deinit(self.gpa);
                        return completed;
                    }
                    try attachToParent(stack, arena, completed);
                },
                .array_end => {
                    // Close the top array frame.
                    var frame = stack.pop().?;
                    const completed = Value{ .array = try frame.array.toOwnedSlice(arena) };
                    if (stack.items.len == 0) {
                        stack.deinit(self.gpa);
                        return completed;
                    }
                    try attachToParent(stack, arena, completed);
                },
                .object_key => |k| {
                    // Copy the key out of the borrowed scratch buffer immediately.
                    const key_copy = try arena.dupe(u8, k);
                    stack.items[top_idx].object.pending_key = key_copy;
                },
                .string => |s| {
                    const v = Value{ .string = try arena.dupe(u8, s) };
                    try attachToParent(stack, arena, v);
                },
                .number => |n| {
                    const v = try self.numberValue(arena, n);
                    try attachToParent(stack, arena, v);
                },
                .boolean => |b| {
                    try attachToParent(stack, arena, .{ .bool = b });
                },
                .null => {
                    try attachToParent(stack, arena, .null);
                },
                .end_of_input => return error.JsonParseError,
            }
        }

        unreachable; // stack empties only when a return above fires
    }

    // Attach a completed child Value to the top frame on the stack.
    fn attachToParent(stack: *std.ArrayList(MaterializeFrame), arena: std.mem.Allocator, child: Value) StreamError!void {
        const parent_idx = stack.items.len - 1;
        switch (stack.items[parent_idx]) {
            .array => |*lst| try lst.append(arena, child),
            .object => |*obj| {
                const k = obj.pending_key orelse return error.JsonParseError;
                try obj.map.put(arena, k, child);
                obj.pending_key = null;
            },
        }
    }
};

// Ergonomic record iterator that wraps an EventReader and yields one Value per
// record. Records are either elements of a top-level JSON array (array_elements),
// whitespace/newline-separated top-level documents (multi_document / NDJSON),
// or auto-detected from the first event (auto).
//
// The caller supplies a per-item allocator (item_arena) to next(); resetting it
// between calls bounds memory to a single record at a time.
//
// In feed-core mode (feed + endInput), a full record must be buffered before
// next() can return a Value; next() returns error.NeedMoreInput mid-record.
// For incremental delivery of large records, use fromReader instead.
pub const ValueStream = struct {
    inner: EventReader,
    // Resolved mode. Starts as the options.shape value; auto is replaced on
    // the first call to next().
    mode: StreamShape,
    // For auto mode: store the first event before we know which branch to take.
    first_event: ?Event = null,
    // Whether the outer array_begin has been consumed (array_elements / auto-array).
    array_started: bool = false,
    // Whether the iterator is exhausted (array_end seen, or end_of_input seen).
    done: bool = false,

    pub fn init(gpa: std.mem.Allocator, options: StreamOptions) ValueStream {
        var vs = ValueStream{
            .inner = EventReader.init(gpa, options),
            .mode = options.shape,
        };
        if (options.shape == .multi_document) vs.inner.allow_multi = true;
        return vs;
    }

    pub fn fromReader(gpa: std.mem.Allocator, reader: *std.Io.Reader, options: StreamOptions) ValueStream {
        var vs = ValueStream{
            .inner = EventReader.fromReader(gpa, reader, options),
            .mode = options.shape,
        };
        if (options.shape == .multi_document) vs.inner.allow_multi = true;
        return vs;
    }

    pub fn deinit(self: *ValueStream) void {
        self.inner.deinit();
    }

    // Forward bytes to the inner EventReader (feed-core variant only).
    pub fn feed(self: *ValueStream, bytes: []const u8) std.mem.Allocator.Error!void {
        return self.inner.feed(bytes);
    }

    pub fn next(self: *ValueStream, item_arena: std.mem.Allocator) StreamError!?Value {
        switch (self.mode) {
            .array_elements => return self.nextArrayElement(item_arena),
            .multi_document => return self.nextDocument(item_arena),
            .auto => return self.nextAuto(item_arena),
        }
    }

    // Consume one element from a top-level array. On the first call, reads and
    // validates the array_begin event. Returns null when array_end is reached,
    // and continues to return null on subsequent calls.
    fn nextArrayElement(self: *ValueStream, item_arena: std.mem.Allocator) StreamError!?Value {
        if (self.done) return null;
        // Resume a record suspended mid-materialize by NeedMoreInput before
        // consuming any further events.
        if (self.inner.mat != null) return try self.inner.materialize(item_arena);
        if (!self.array_started) {
            const ev = (try self.inner.next()) orelse return error.JsonParseError;
            if (ev.kind != .array_begin) return error.JsonParseError;
            self.array_started = true;
        }
        const ev = (try self.inner.next()) orelse return error.JsonParseError;
        return switch (ev.kind) {
            .array_end => {
                self.done = true;
                return null;
            },
            .object_begin, .array_begin, .string, .number, .boolean, .null => try self.inner.materialize(item_arena),
            else => error.JsonParseError,
        };
    }

    // Consume one top-level document from a multi-document stream. Returns null
    // when end_of_input is reached, and continues to return null on subsequent calls.
    fn nextDocument(self: *ValueStream, item_arena: std.mem.Allocator) StreamError!?Value {
        if (self.done) return null;
        // Resume a record suspended mid-materialize by NeedMoreInput before
        // consuming any further events.
        if (self.inner.mat != null) return try self.inner.materialize(item_arena);
        const ev = (try self.inner.next()) orelse {
            self.done = true;
            return null;
        };
        return switch (ev.kind) {
            .end_of_input => {
                self.done = true;
                return null;
            },
            .object_begin, .array_begin, .string, .number, .boolean, .null => try self.inner.materialize(item_arena),
            else => error.JsonParseError,
        };
    }

    // Resolve the shape from the first event, then delegate. If the first event
    // is array_begin, switch to array_elements (that begin is consumed). Otherwise
    // switch to multi_document and materialize starting from that first event (so
    // the value is not dropped).
    fn nextAuto(self: *ValueStream, item_arena: std.mem.Allocator) StreamError!?Value {
        // Peek the first event to decide mode.
        const first = if (self.first_event) |fe| fe else blk: {
            const ev = (try self.inner.next()) orelse {
                self.mode = .multi_document;
                return null;
            };
            self.first_event = ev;
            break :blk ev;
        };

        switch (first.kind) {
            .array_begin => {
                // Switch to array_elements; the array_begin is already consumed.
                self.mode = .array_elements;
                self.first_event = null;
                self.array_started = true;
                return self.nextArrayElement(item_arena);
            },
            .end_of_input => {
                self.mode = .multi_document;
                self.first_event = null;
                return null;
            },
            .object_begin, .string, .number, .boolean, .null => {
                // Switch to multi_document. The first event is already set as `last`
                // in the inner reader, so materialize() will use it.
                self.mode = .multi_document;
                self.inner.allow_multi = true;
                self.first_event = null;
                return try self.inner.materialize(item_arena);
            },
            else => return error.JsonParseError,
        }
    }
};

// Helper: feed a complete input, end it, return the first event. The caller
// owns the EventReader and must call deinit after inspecting slices in the event
// (number/string payloads borrow from the reader's internal buffers).
fn initSingle(src: []const u8, opts: StreamOptions) !EventReader {
    var er = EventReader.init(testing.allocator, opts);
    errdefer er.deinit();
    try er.feed(src);
    er.endInput();
    return er;
}

test "scalar literals" {
    {
        var er = try initSingle("null", .{});
        defer er.deinit();
        const ev = (try er.next()).?;
        try testing.expectEqual(Event.Kind.null, std.meta.activeTag(ev.kind));
    }
    {
        var er = try initSingle("true", .{});
        defer er.deinit();
        const ev = (try er.next()).?;
        try testing.expectEqual(true, ev.kind.boolean);
    }
    {
        var er = try initSingle("false", .{});
        defer er.deinit();
        const ev = (try er.next()).?;
        try testing.expectEqual(false, ev.kind.boolean);
    }
}

test "scalar number keeps raw lexeme and coerces" {
    {
        var er = try initSingle("  -12.5e3 ", .{});
        defer er.deinit();
        const ev = (try er.next()).?;
        try testing.expectEqualStrings("-12.5e3", ev.kind.number);
        try testing.expectEqual(@as(f64, -12500.0), asFloat(ev.kind.number).?);
    }
    {
        var er = try initSingle("42", .{});
        defer er.deinit();
        const ev = (try er.next()).?;
        try testing.expectEqual(@as(i128, 42), asInt(ev.kind.number).?);
    }
}

test "asInt: i128 range, non-integer returns null" {
    // i64max+1 must parse -- this is the regression the widening fixes.
    try testing.expectEqual(@as(?i128, 9223372036854775808), asInt("9223372036854775808"));
    // Small integer still works.
    try testing.expectEqual(@as(?i128, 42), asInt("42"));
    try testing.expectEqual(@as(?i128, -1), asInt("-1"));
    // Float lexeme is not an integer.
    try testing.expectEqual(@as(?i128, null), asInt("1.5"));
    try testing.expectEqual(@as(?i128, null), asInt("1e2"));
    // Malformed bytes return null (not a silent float).
    try testing.expectEqual(@as(?i128, null), asInt("abc"));
}

test "asInt and materialize agree for number in (i64max, i128max]" {
    // Parse a value above i64max as a streaming number event and via materialize;
    // both must see it as .integer with the same value.
    const big = "9223372036854775808"; // i64max+1
    const a = testing.allocator;
    var er = try initSingle(big, .{});
    defer er.deinit();
    const ev = (try er.next()).?;
    // asInt on the raw lexeme must return the full i128 value.
    const as_int = asInt(ev.kind.number).?;
    try testing.expectEqual(@as(i128, 9223372036854775808), as_int);
    // materialize() on the same reader (which already consumed the event via
    // next(); materialize uses self.last so no second next() call needed).
    const mat = try er.materialize(a);
    try testing.expectEqual(@as(i128, 9223372036854775808), mat.integer);
}

test "scalar string decodes escapes" {
    var er = try initSingle("\"a\\n\\u0041b\"", .{});
    defer er.deinit();
    const ev = (try er.next()).?;
    try testing.expectEqualStrings("a\nAb", ev.kind.string);
}

test "bare invalid scalar is a parse error" {
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("@");
    er.endInput();
    try testing.expectError(error.JsonParseError, er.next());
}

test "scalar string surrogate pair decodes emoji" {
    // U+1F600 (GRINNING FACE) encoded as surrogate pair.
    // UTF-8 representation: F0 9F 98 80.
    var er = try initSingle("\"\\uD83D\\uDE00\"", .{});
    defer er.deinit();
    const ev = (try er.next()).?;
    try testing.expectEqualStrings("\xF0\x9F\x98\x80", ev.kind.string);
}

test "surrogate escape errors" {
    const a = testing.allocator;
    // Lone low surrogate.
    {
        var er = EventReader.init(a, .{});
        defer er.deinit();
        try er.feed("\"\\uDE00\"");
        er.endInput();
        try testing.expectError(error.JsonParseError, er.next());
    }
    // Unpaired high surrogate (followed by non-surrogate codepoint).
    {
        var er = EventReader.init(a, .{});
        defer er.deinit();
        try er.feed("\"\\uD83D\\u0041\"");
        er.endInput();
        try testing.expectError(error.JsonParseError, er.next());
    }
}

test "trailing identifier bytes on keyword are rejected" {
    {
        var er = try initSingle("truex", .{});
        defer er.deinit();
        try testing.expectError(error.JsonParseError, er.next());
    }
    {
        var er = try initSingle("nullx", .{});
        defer er.deinit();
        try testing.expectError(error.JsonParseError, er.next());
    }
    {
        var er = try initSingle("falsey", .{});
        defer er.deinit();
        try testing.expectError(error.JsonParseError, er.next());
    }
}

test "partial keyword in ended buffer is UnexpectedEndOfInput" {
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("nul");
    er.endInput();
    try testing.expectError(error.UnexpectedEndOfInput, er.next());
}

test "mismatched close brackets are rejected" {
    // Array opened, object-close.
    {
        var er = EventReader.init(testing.allocator, .{});
        defer er.deinit();
        try er.feed("[1}");
        er.endInput();
        var i: usize = 0;
        const result = while (i < 50) : (i += 1) {
            const ev = er.next() catch |e| break e;
            if (std.meta.activeTag(ev.?.kind) == .end_of_input) break error.NoError;
        } else error.Looped;
        try testing.expectEqual(error.JsonParseError, result);
    }
    // Object opened, array-close.
    {
        var er = EventReader.init(testing.allocator, .{});
        defer er.deinit();
        try er.feed("{\"a\": 1]");
        er.endInput();
        var i: usize = 0;
        const result = while (i < 50) : (i += 1) {
            const ev = er.next() catch |e| break e;
            if (std.meta.activeTag(ev.?.kind) == .end_of_input) break error.NoError;
        } else error.Looped;
        try testing.expectEqual(error.JsonParseError, result);
    }
}

test "flat object event sequence" {
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("{\"a\": 1, \"b\": true}");
    er.endInput();
    try testing.expectEqual(Event.Kind.object_begin, std.meta.activeTag((try er.next()).?.kind));
    try testing.expectEqualStrings("a", (try er.next()).?.kind.object_key);
    try testing.expectEqualStrings("1", (try er.next()).?.kind.number);
    try testing.expectEqualStrings("b", (try er.next()).?.kind.object_key);
    try testing.expectEqual(true, (try er.next()).?.kind.boolean);
    try testing.expectEqual(Event.Kind.object_end, std.meta.activeTag((try er.next()).?.kind));
    try testing.expectEqual(Event.Kind.end_of_input, std.meta.activeTag((try er.next()).?.kind));
}

test "nested arrays and objects" {
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("[1, {\"k\": [2]}]");
    er.endInput();
    const tags = [_]std.meta.Tag(Event.Kind){ .array_begin, .number, .object_begin, .object_key, .array_begin, .number, .array_end, .object_end, .array_end, .end_of_input };
    for (tags) |want| try testing.expectEqual(want, std.meta.activeTag((try er.next()).?.kind));
}

test "max_depth fires fast, does not recurse the host stack" {
    var er = EventReader.init(testing.allocator, .{ .max_depth = 4 });
    defer er.deinit();
    try er.feed("[[[[[1]]]]]");
    er.endInput();
    var i: usize = 0;
    const result = while (i < 100) : (i += 1) {
        const ev = er.next() catch |e| break e;
        if (std.meta.activeTag(ev.?.kind) == .end_of_input) break error.NoError;
    } else error.Looped;
    try testing.expectEqual(error.NestingTooDeep, result);
}

test "structural errors: trailing comma in strict json" {
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("[1,]");
    er.endInput();
    _ = try er.next(); // array_begin
    _ = try er.next(); // number 1
    try testing.expectError(error.JsonParseError, er.next());
}

// Collect event tags by feeding src all at once, then ending input.
fn eventTagsWhole(a: std.mem.Allocator, src: []const u8) ![]std.meta.Tag(Event.Kind) {
    var er = EventReader.init(a, .{});
    defer er.deinit();
    try er.feed(src);
    er.endInput();
    var out: std.ArrayList(std.meta.Tag(Event.Kind)) = .empty;
    while (try er.next()) |ev| {
        try out.append(a, std.meta.activeTag(ev.kind));
        if (std.meta.activeTag(ev.kind) == .end_of_input) break;
    }
    return out.toOwnedSlice(a);
}

// Collect event tags by feeding src[0..at], driving next() until NeedMoreInput,
// then feeding the rest, calling endInput, and draining.
fn eventTagsSplit(a: std.mem.Allocator, src: []const u8, at: usize) ![]std.meta.Tag(Event.Kind) {
    var er = EventReader.init(a, .{});
    defer er.deinit();
    var fed: usize = 0;
    var out: std.ArrayList(std.meta.Tag(Event.Kind)) = .empty;
    try er.feed(src[0..at]);
    fed = at;
    while (true) {
        const r = er.next() catch |e| switch (e) {
            error.NeedMoreInput => {
                if (fed < src.len) { try er.feed(src[fed..]); fed = src.len; er.endInput(); continue; }
                er.endInput();
                continue;
            },
            else => return e,
        };
        const ev = r orelse break;
        try out.append(a, std.meta.activeTag(ev.kind));
        if (std.meta.activeTag(ev.kind) == .end_of_input) break;
    }
    return out.toOwnedSlice(a);
}

test "event stream is identical at every split point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "{\"name\": \"Ada Lovelace\", \"ids\": [1, 2, 30000], \"ok\": true, \"x\": null}";
    const whole = try eventTagsWhole(a, src);
    var at: usize = 0;
    while (at <= src.len) : (at += 1) {
        const split = try eventTagsSplit(a, src, at);
        try testing.expectEqualSlices(std.meta.Tag(Event.Kind), whole, split);
    }
}

test "max_token_len caps a single huge string fast" {
    var er = EventReader.init(testing.allocator, .{ .max_token_len = 8 });
    defer er.deinit();
    try er.feed("\"abcdefghijklmnop\"");
    er.endInput();
    try testing.expectError(error.TokenTooLong, er.next());
}

test "max_token_len enforced for numbers at boundary" {
    // 9-digit number must be rejected when max_token_len = 8.
    {
        var er = EventReader.init(testing.allocator, .{ .max_token_len = 8 });
        defer er.deinit();
        try er.feed("123456789");
        er.endInput();
        try testing.expectError(error.TokenTooLong, er.next());
    }
    // 8-digit number must be accepted.
    {
        var er = EventReader.init(testing.allocator, .{ .max_token_len = 8 });
        defer er.deinit();
        try er.feed("12345678");
        er.endInput();
        const ev = (try er.next()).?;
        try testing.expectEqual(Event.Kind.number, std.meta.activeTag(ev.kind));
        try testing.expectEqualStrings("12345678", ev.kind.number);
    }
}

// Collect event tags by feeding src one byte at a time. On NeedMoreInput, feed
// exactly one more byte (not the remainder). endInput() is called only after the
// last byte has been fed. This is the strongest resumption stress test.
fn eventTagsOneByte(a: std.mem.Allocator, src: []const u8) ![]std.meta.Tag(Event.Kind) {
    var er = EventReader.init(a, .{});
    defer er.deinit();
    var fed: usize = 0;
    var out: std.ArrayList(std.meta.Tag(Event.Kind)) = .empty;
    // Seed with the first byte so the loop can always feed one more on NeedMoreInput.
    if (src.len > 0) {
        try er.feed(src[0..1]);
        fed = 1;
    } else {
        er.endInput();
    }
    while (true) {
        const r = er.next() catch |e| switch (e) {
            error.NeedMoreInput => {
                if (fed < src.len) {
                    try er.feed(src[fed .. fed + 1]);
                    fed += 1;
                } else {
                    er.endInput();
                }
                continue;
            },
            else => return e,
        };
        const ev = r orelse break;
        try out.append(a, std.meta.activeTag(ev.kind));
        if (std.meta.activeTag(ev.kind) == .end_of_input) break;
    }
    return out.toOwnedSlice(a);
}

test "event stream is identical when fed one byte at a time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "{\"name\": \"Ada Lovelace\", \"ids\": [1, 2, 30000], \"ok\": true, \"x\": null}";
    const whole = try eventTagsWhole(a, src);
    const one_byte = try eventTagsOneByte(a, src);
    try testing.expectEqualSlices(std.meta.Tag(Event.Kind), whole, one_byte);
}

test "keyword boundary: split inside keyword then valid ending yields event" {
    // Feed "tru", get NeedMoreInput, feed "e" with endInput, get boolean=true.
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("tru");
    try testing.expectError(error.NeedMoreInput, er.next());
    try er.feed("e");
    er.endInput();
    const ev = (try er.next()).?;
    try testing.expectEqual(true, ev.kind.boolean);
}

test "keyword boundary: split where trailing byte makes it invalid" {
    // Feed "true" (not ended), get NeedMoreInput, feed "x" with endInput, get parse error.
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("true");
    try testing.expectError(error.NeedMoreInput, er.next());
    try er.feed("x");
    er.endInput();
    try testing.expectError(error.JsonParseError, er.next());
}

test "fromReader walks a document without NeedMoreInput" {
    var r: std.Io.Reader = .fixed("[1, 2, 3]");
    var er = EventReader.fromReader(testing.allocator, &r, .{});
    defer er.deinit();
    const tags = [_]std.meta.Tag(Event.Kind){ .array_begin, .number, .number, .number, .array_end, .end_of_input };
    for (tags) |want| try testing.expectEqual(want, std.meta.activeTag((try er.next()).?.kind));
}

test "fromReader multi-chunk: document larger than 4096 bytes" {
    // Larger than the 4096-byte pull buffer, so fromReader must pull multiple chunks.
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.append(a, '[');
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        if (i > 0) try src.appendSlice(a, ",");
        try src.appendSlice(a, "123456789");
    }
    try src.append(a, ']');

    var r: std.Io.Reader = .fixed(src.items);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();

    var count: usize = 0;
    var got_array_begin = false;
    var got_array_end = false;
    while (try er.next()) |ev| {
        switch (std.meta.activeTag(ev.kind)) {
            .array_begin => got_array_begin = true,
            .array_end => got_array_end = true,
            .number => count += 1,
            .end_of_input => break,
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expect(got_array_begin);
    try testing.expect(got_array_end);
    try testing.expectEqual(@as(usize, 500), count);
}

test "diagnostic carries a span and renders rich" {
    // Input: [1 2]  offsets: [=0  1=1  ' '=2  2=3  ]=4
    // The missing comma error fires when '2' is seen; its span must start at 3.
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("[1 2]");
    er.endInput();
    _ = try er.next(); // array_begin
    _ = try er.next(); // number 1
    try testing.expectError(error.JsonParseError, er.next());
    const d = er.diagnostic().?;
    try testing.expectEqual(@as(u32, 3), d.span.start);
}

test "jsonc comments and trailing comma stream" {
    var er = EventReader.init(testing.allocator, .{ .dialect = .jsonc });
    defer er.deinit();
    try er.feed("[ 1, /* x */ 2, ]");
    er.endInput();
    const tags = [_]std.meta.Tag(Event.Kind){ .array_begin, .number, .number, .array_end, .end_of_input };
    for (tags) |want| try testing.expectEqual(want, std.meta.activeTag((try er.next()).?.kind));
}

test "jsonc line comment is skipped" {
    var er = EventReader.init(testing.allocator, .{ .dialect = .jsonc });
    defer er.deinit();
    try er.feed("[ 1 // comment\n, 2 ]");
    er.endInput();
    const tags = [_]std.meta.Tag(Event.Kind){ .array_begin, .number, .number, .array_end, .end_of_input };
    for (tags) |want| try testing.expectEqual(want, std.meta.activeTag((try er.next()).?.kind));
}

test "strict json: slash is a parse error" {
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("[ // comment ]");
    er.endInput();
    _ = try er.next(); // array_begin
    try testing.expectError(error.JsonParseError, er.next());
}

test "endInput mid-token is UnexpectedEndOfInput" {
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("[1, 2");
    er.endInput();
    _ = try er.next(); // array_begin
    _ = try er.next(); // number 1
    _ = try er.next(); // number 2
    try testing.expectError(error.UnexpectedEndOfInput, er.next());
}

test "jsonc block comment split across feed boundary is skipped" {
    // The comment `/* hi */` is split: first feed has `/* hi`, second has ` */`.
    var er = EventReader.init(testing.allocator, .{ .dialect = .jsonc });
    defer er.deinit();
    try er.feed("[/* hi");
    // At this point next() should return NeedMoreInput (block comment incomplete).
    _ = try er.next(); // array_begin succeeds (bracket consumed before comment)
    try testing.expectError(error.NeedMoreInput, er.next());
    try er.feed(" */1]");
    er.endInput();
    // Now the comment is complete; number 1 follows.
    const ev = (try er.next()).?;
    try testing.expectEqual(Event.Kind.number, std.meta.activeTag(ev.kind));
    const ev2 = (try er.next()).?;
    try testing.expectEqual(Event.Kind.array_end, std.meta.activeTag(ev2.kind));
}

// Finding 1: truncated scalars at end-of-input must yield UnexpectedEndOfInput.

test "truncated string at end-of-input is UnexpectedEndOfInput" {
    // `"abc` has no closing quote; the token was cut off by EOF.
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("\"abc");
    er.endInput();
    try testing.expectError(error.UnexpectedEndOfInput, er.next());
    try testing.expect(er.diagnostic() != null);
}

test "truncated keyword at end-of-input is UnexpectedEndOfInput" {
    // `nul` (3 bytes) is fewer than the 4-byte keyword `null`; cut off by EOF.
    // (Renamed from the old test that expected JsonParseError.)
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("nul");
    er.endInput();
    try testing.expectError(error.UnexpectedEndOfInput, er.next());
    try testing.expect(er.diagnostic() != null);
}

test "truncated number dash at end-of-input is UnexpectedEndOfInput" {
    // `-` alone is not a valid number; it was cut off before any digit arrived.
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("-");
    er.endInput();
    try testing.expectError(error.UnexpectedEndOfInput, er.next());
    try testing.expect(er.diagnostic() != null);
}

test "valid number at end-of-input is accepted" {
    // `12` is a complete valid number; EOF does not truncate it.
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("12");
    er.endInput();
    const ev = (try er.next()).?;
    try testing.expectEqual(Event.Kind.number, std.meta.activeTag(ev.kind));
    try testing.expectEqualStrings("12", ev.kind.number);
}

test "structurally invalid input at end-of-input stays JsonParseError" {
    // Missing comma in `[1 2]` is structural; more bytes would not fix it.
    {
        var er = EventReader.init(testing.allocator, .{});
        defer er.deinit();
        try er.feed("[1 2]");
        er.endInput();
        _ = try er.next(); // array_begin
        _ = try er.next(); // number 1
        try testing.expectError(error.JsonParseError, er.next());
    }
    // `@` is always invalid regardless of what follows.
    {
        var er = EventReader.init(testing.allocator, .{});
        defer er.deinit();
        try er.feed("@");
        er.endInput();
        try testing.expectError(error.JsonParseError, er.next());
    }
}

// Finding 2: JSONC all-split-points equivalence sweep.

// Like eventTagsWhole but passes jsonc options.
fn eventTagsWholeJsonc(a: std.mem.Allocator, src: []const u8) ![]std.meta.Tag(Event.Kind) {
    var er = EventReader.init(a, .{ .dialect = .jsonc });
    defer er.deinit();
    try er.feed(src);
    er.endInput();
    var out: std.ArrayList(std.meta.Tag(Event.Kind)) = .empty;
    while (try er.next()) |ev| {
        try out.append(a, std.meta.activeTag(ev.kind));
        if (std.meta.activeTag(ev.kind) == .end_of_input) break;
    }
    return out.toOwnedSlice(a);
}

// Like eventTagsSplit but passes jsonc options.
fn eventTagsSplitJsonc(a: std.mem.Allocator, src: []const u8, at: usize) ![]std.meta.Tag(Event.Kind) {
    var er = EventReader.init(a, .{ .dialect = .jsonc });
    defer er.deinit();
    var fed: usize = 0;
    var out: std.ArrayList(std.meta.Tag(Event.Kind)) = .empty;
    try er.feed(src[0..at]);
    fed = at;
    while (true) {
        const r = er.next() catch |e| switch (e) {
            error.NeedMoreInput => {
                if (fed < src.len) { try er.feed(src[fed..]); fed = src.len; er.endInput(); continue; }
                er.endInput();
                continue;
            },
            else => return e,
        };
        const ev = r orelse break;
        try out.append(a, std.meta.activeTag(ev.kind));
        if (std.meta.activeTag(ev.kind) == .end_of_input) break;
    }
    return out.toOwnedSlice(a);
}

test "jsonc event stream is identical at every split point" {
    // Exercises comment-resumption at all chunk boundaries.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "[ 1, /* mid */ 2, // tail\n 3 ]";
    const whole = try eventTagsWholeJsonc(a, src);
    var at: usize = 0;
    while (at <= src.len) : (at += 1) {
        const split = try eventTagsSplitJsonc(a, src, at);
        try testing.expectEqualSlices(std.meta.Tag(Event.Kind), whole, split);
    }
}

test "materialize an array element subtree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("[{\"id\": 1, \"name\": \"x\"}, 99]");
    er.endInput();
    _ = try er.next(); // array_begin
    const first = try er.next(); // object_begin (positioned at value start)
    try testing.expectEqual(Event.Kind.object_begin, std.meta.activeTag(first.?.kind));
    const v = try er.materialize(a);
    try testing.expectEqual(@as(i64, 1), v.getT(i64, "id").?);
    try testing.expectEqualStrings("x", v.getT([]const u8, "name").?);
    // reader continues past the object to the next element
    try testing.expectEqualStrings("99", (try er.next()).?.kind.number);
}

test "materialize a scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("[7]");
    er.endInput();
    _ = try er.next(); // array_begin
    _ = try er.next(); // number 7 (current event is the scalar)
    const v = try er.materialize(a);
    try testing.expectEqual(@as(i128, 7), v.integer);
}

test "materialize nested array/object exercises explicit stack" {
    // Materializes [[1,2],{"a":[3]}] as element 0, then checks element 1 in that tree.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("[ [[1,2],{\"a\":[3]}] ]");
    er.endInput();
    _ = try er.next(); // outer array_begin
    _ = try er.next(); // inner array_begin
    const v = try er.materialize(a);
    // v is [[1,2],{"a":[3]}]
    try testing.expect(v == .array);
    try testing.expectEqual(@as(usize, 2), v.array.len);
    // v[0] is [1,2]
    const v0 = v.array[0];
    try testing.expect(v0 == .array);
    try testing.expectEqual(@as(i128, 1), v0.array[0].integer);
    try testing.expectEqual(@as(i128, 2), v0.array[1].integer);
    // v[1] is {"a":[3]}
    const v1 = v.array[1];
    try testing.expectEqual(@as(i64, 3), v1.getT(i64, "a[0]").?);
    // outer array still has the close event waiting
    const close = try er.next();
    try testing.expectEqual(Event.Kind.array_end, std.meta.activeTag(close.?.kind));
}

test "materialize honors number_mode raw" {
    // In raw mode every number becomes .number_raw regardless of magnitude.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var er = EventReader.init(testing.allocator, .{ .number_mode = .raw });
    defer er.deinit();
    try er.feed("99999999999999999999");
    er.endInput();
    _ = try er.next(); // number event
    const v = try er.materialize(a);
    try testing.expect(v == .number_raw);
    try testing.expectEqualStrings("99999999999999999999", v.number_raw);
}

test "materialize strings survive after buffer slide" {
    // After materializing, call next() several times to slide the internal buffer,
    // then read the materialized string to confirm it was arena-copied, not borrowed.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("[{\"greeting\": \"hello\"}, 1, 2, 3]");
    er.endInput();
    _ = try er.next(); // array_begin
    _ = try er.next(); // object_begin
    const v = try er.materialize(a);
    // Advance the reader past several more elements to force buffer compaction.
    _ = try er.next(); // number 1
    _ = try er.next(); // number 2
    _ = try er.next(); // number 3
    _ = try er.next(); // array_end
    // The materialized string must still be valid (arena copy, not borrowed buf).
    try testing.expectEqualStrings("hello", v.getT([]const u8, "greeting").?);
}

test "materialize error: not at a value start" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("{\"k\": 1}");
    er.endInput();
    _ = try er.next(); // object_begin
    _ = try er.next(); // object_key "k"
    // Last event is object_key, not a value start: must error.
    try testing.expectError(error.JsonParseError, er.materialize(a));
}

test "ValueStream over a top-level array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r: std.Io.Reader = .fixed("[{\"n\":1}, {\"n\":2}, {\"n\":3}]");
    var vs = ValueStream.fromReader(testing.allocator, &r, .{ .shape = .array_elements });
    defer vs.deinit();
    var sum: i64 = 0;
    while (try vs.next(arena.allocator())) |v| sum += v.getT(i64, "n").?;
    try testing.expectEqual(@as(i64, 6), sum);
    // next() after the array is exhausted must return null.
    try testing.expectEqual(@as(?Value, null), try vs.next(arena.allocator()));
}

test "ValueStream over NDJSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r: std.Io.Reader = .fixed("{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n");
    var vs = ValueStream.fromReader(testing.allocator, &r, .{ .shape = .multi_document });
    defer vs.deinit();
    var count: usize = 0;
    while (try vs.next(arena.allocator())) |_| count += 1;
    try testing.expectEqual(@as(usize, 3), count);
}

test "ValueStream auto-detects array vs documents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r1: std.Io.Reader = .fixed("[1,2]");
    var vs1 = ValueStream.fromReader(testing.allocator, &r1, .{ .shape = .auto });
    defer vs1.deinit();
    try testing.expectEqual(@as(i128, 1), (try vs1.next(arena.allocator())).?.integer);
    try testing.expectEqual(@as(i128, 2), (try vs1.next(arena.allocator())).?.integer);
    try testing.expectEqual(@as(?Value, null), try vs1.next(arena.allocator()));
}

test "ValueStream auto on multi_document does not drop first value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r: std.Io.Reader = .fixed("{\"a\":1} {\"a\":2}");
    var vs = ValueStream.fromReader(testing.allocator, &r, .{ .shape = .auto });
    defer vs.deinit();
    const v1 = (try vs.next(arena.allocator())).?;
    try testing.expectEqual(@as(i64, 1), v1.getT(i64, "a").?);
    const v2 = (try vs.next(arena.allocator())).?;
    try testing.expectEqual(@as(i64, 2), v2.getT(i64, "a").?);
    try testing.expectEqual(@as(?Value, null), try vs.next(arena.allocator()));
}

test "ValueStream array per-item arena reset works without corruption" {
    // Drive the array stream resetting item_arena between items. Values from
    // earlier items should not be visible (their memory is reused) and the
    // stream must not error or corrupt later items.
    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();
    var r: std.Io.Reader = .fixed("[{\"n\":10}, {\"n\":20}, {\"n\":30}]");
    var vs = ValueStream.fromReader(testing.allocator, &r, .{ .shape = .array_elements });
    defer vs.deinit();
    const expected = [_]i64{ 10, 20, 30 };
    var idx: usize = 0;
    while (try vs.next(item_arena.allocator())) |v| {
        try testing.expectEqual(expected[idx], v.getT(i64, "n").?);
        _ = item_arena.reset(.retain_capacity);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 3), idx);
}

test "strict regression: EventReader on two top-level values errors without allow_multi" {
    // Direct EventReader usage (allow_multi = false by default) must still reject
    // a second top-level value. "1 2" has two top-level values; after the first
    // is consumed, the second must produce JsonParseError.
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    try er.feed("1 2");
    er.endInput();
    _ = try er.next(); // number 1 succeeds
    // The second next() skips whitespace, sees '2', and hits the top_done guard.
    try testing.expectError(error.JsonParseError, er.next());
}

test "unbounded streaming: events flow past 4 GiB, spans stay exact" {
    // Inject base past maxInt(u32) (the old 4-GiB cap) without allocating
    // gigabytes. Events keep flowing with CORRECT data, and u64 spans record
    // the exact absolute offset past 4 GiB. Bounded: 3 bytes fed.
    const base = @as(u64, std.math.maxInt(u32)) + 100;
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    er.base = base;
    try er.feed("[1]");
    er.endInput();

    const begin = (try er.next()).?;
    try testing.expectEqual(Event.Kind.array_begin, std.meta.activeTag(begin.kind));
    // Span offset is past 4 GiB: u64 records it exactly, no saturation.
    try testing.expectEqual(base, begin.span.start);

    const num = (try er.next()).?;
    try testing.expectEqualStrings("1", num.kind.number); // data is correct
    try testing.expectEqual(base + 1, num.span.start);

    const end = (try er.next()).?;
    try testing.expectEqual(Event.Kind.array_end, std.meta.activeTag(end.kind));
    const eoi = (try er.next()).?;
    try testing.expectEqual(Event.Kind.end_of_input, std.meta.activeTag(eoi.kind));
}

test "streaming at the old 4-GiB boundary no longer errors" {
    // Exactly the old cap-trigger condition (base + buf.len > maxInt(u32)).
    // Previously this returned error.StreamTooLong; now it must parse.
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    er.base = std.math.maxInt(u32) - 1;
    try er.feed("[1]");
    er.endInput();
    const begin = (try er.next()).?;
    try testing.expectEqual(Event.Kind.array_begin, std.meta.activeTag(begin.kind));
    const num = (try er.next()).?;
    try testing.expectEqualStrings("1", num.kind.number);
}

test "whole-feed large array drains linearly with bounded buffer" {
    // Regression guard for the O(n^2) compaction DoS: feeding an entire array at
    // once and draining it must stay linear. Quadratic compaction (shifting the
    // whole unconsumed remainder on every next()) blows far past the wall-clock
    // budget. The timer is polled inside the drain loop so a regression fails
    // fast rather than running for tens of seconds.
    const a = testing.allocator;
    const n: usize = 150_000;

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.append(a, '[');
    var k: usize = 0;
    while (k < n) : (k += 1) {
        if (k > 0) try src.append(a, ',');
        try src.append(a, '1');
    }
    try src.append(a, ']');

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var er = EventReader.init(a, .{});
    defer er.deinit();
    try er.feed(src.items);
    er.endInput();

    const budget_ns: u64 = 3 * std.time.ns_per_s;
    const t0: std.Io.Timestamp = .now(io, .awake);

    var count: usize = 0;
    var checks: usize = 0;
    while (try er.next()) |ev| {
        const tag = std.meta.activeTag(ev.kind);
        if (tag == .number) count += 1;
        if (tag == .end_of_input) break;
        checks += 1;
        if (checks & 0x3fff == 0) {
            const elapsed: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
            if (elapsed > budget_ns) return error.CompactionTooSlow;
        }
    }
    const total_ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);

    try testing.expectEqual(n, count);
    try testing.expect(total_ns <= budget_ns);
    // The buffer holds the whole fed document (inherent to whole-feed), but the
    // fix must not balloon it: capacity stays within a small factor of the input,
    // far under max_token_len -- proving we did not trade the quadratic for
    // unbounded memory.
    try testing.expect(er.buf.capacity <= src.items.len * 4);
}

test "spans past 4 GiB are exact (u64)" {
    // A base offset just below maxInt(u32) must yield exact u64 span
    // offsets across the 4 GiB boundary -- no truncation, no spurious guard.
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    er.base = std.math.maxInt(u32) - 100;
    try er.feed("42");
    er.endInput();
    const ev = (try er.next()).?;
    try testing.expectEqual(Event.Kind.number, std.meta.activeTag(ev.kind));
    try testing.expectEqualStrings("42", ev.kind.number);
}

test "materialize suspends on NeedMoreInput and resumes the same record" {
    // A mid-record NeedMoreInput used to discard the partial container;
    // the retry then re-entered the event stream mid-record and returned
    // silently wrong data ({"n":1} came back as bare 1).
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try er.feed("{\"n\":");
    const ev = (try er.next()).?;
    try testing.expectEqual(Event.Kind.object_begin, std.meta.activeTag(ev.kind));
    try testing.expectError(error.NeedMoreInput, er.materialize(arena.allocator()));
    try er.feed("1, \"m\": [2, 3]}");
    er.endInput();
    const v = try er.materialize(arena.allocator());
    try testing.expectEqual(@as(i128, 1), v.object.get("n").?.integer);
    try testing.expectEqual(@as(usize, 2), v.object.get("m").?.array.len);
}

test "ValueStream feed-core: mid-record NeedMoreInput retry returns the whole record" {
    const er = EventReader.init(testing.allocator, .{});
    var vs = ValueStream{ .inner = er, .mode = .multi_document };
    defer vs.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try vs.inner.feed("{\"n\":");
    vs.inner.allow_multi = true;
    try testing.expectError(error.NeedMoreInput, vs.next(arena.allocator()));
    try vs.inner.feed("1}{\"n\":2}");
    vs.inner.endInput();
    const v1 = (try vs.next(arena.allocator())).?;
    try testing.expectEqual(@as(i128, 1), v1.object.get("n").?.integer);
    const v2 = (try vs.next(arena.allocator())).?;
    try testing.expectEqual(@as(i128, 2), v2.object.get("n").?.integer);
    try testing.expectEqual(@as(?Value, null), try vs.next(arena.allocator()));
}

test "feed() invalidates the last event: stale materialize fails instead of dangling" {
    var er = EventReader.init(testing.allocator, .{});
    defer er.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try er.feed("\"hello\"");
    er.endInput();
    const ev = (try er.next()).?;
    try testing.expectEqual(Event.Kind.string, std.meta.activeTag(ev.kind));
    // feed() may move the buffer the payload borrows; last is cleared so
    // this is a loud error, not a read of moved memory.
    try er.feed(" ");
    try testing.expectError(error.JsonParseError, er.materialize(arena.allocator()));
}
