//! Streaming token-level lexer.
//!
//! Yields one `Token` at a time from a source slice, without building a
//! value tree. Useful for tooling: syntax highlighters, incremental
//! re-parse, format-preserving editors that need to walk the source
//! token-by-token.
//!
//! ```zig
//! var t: json.Tokenizer = .init(src, .jsonc);
//! while (t.next()) |tok| switch (tok.kind) {
//!     .string => std.debug.print("string {s}\n", .{src[tok.span.start..tok.span.end]}),
//!     .number => ...,
//!     ...
//! }
//! ```
//!
//! The tokenizer is purely lexical: it finds token bounds and rejects
//! malformed lexemes (bad number grammar, unterminated strings), but
//! does not validate string escapes or enforce structural grammar.

const std = @import("std");
const lex = @import("lex.zig");

pub const Span = @import("value.zig").Span;

/// Input dialect: strict RFC 8259 JSON, or JSONC (JSON with `//` and
/// `/* */` comments).
pub const Dialect = enum { json, jsonc };

pub const Kind = enum {
    /// `{`
    object_begin,
    /// `}`
    object_end,
    /// `[`
    array_begin,
    /// `]`
    array_end,
    /// `:`
    colon,
    /// `,`
    comma,
    /// A `"..."` string literal; the span includes both quotes.
    string,
    /// An RFC 8259 number literal.
    number,
    /// `true`
    literal_true,
    /// `false`
    literal_false,
    /// `null`
    literal_null,
    /// A `// ...` or `/* ... */` comment (`.jsonc` only).
    comment,
    /// Unrecognized or malformed byte sequence; the span covers whatever
    /// the tokenizer chose to consume. Tooling can highlight as an error.
    invalid,
};

pub const Token = struct {
    kind: Kind,
    span: Span,
};

/// Internal token with usize byte offsets, so tokenizing never narrows
/// `pos` on the hot path. The byte offsets index the input directly. Line
/// and column are not tracked; derive them on demand with `Span.lineCol`.
pub const RawToken = struct {
    kind: Kind,
    start: usize,
    end: usize,
};

/// Cursor used during scanning. `pos` is usize so the scanners address any
/// in-memory input directly.
const Mark = struct {
    pos: usize,
};

pub const Tokenizer = struct {
    input: []const u8,
    dialect: Dialect,
    pos: usize = 0,

    pub fn init(input: []const u8, dialect: Dialect) Tokenizer {
        return .{ .input = input, .dialect = dialect };
    }

    /// Public token API. Byte offsets are u64, so any in-memory input is
    /// addressable; line/col are derived on demand via `Span.lineCol`.
    pub fn next(self: *Tokenizer) ?Token {
        const raw = self.nextRaw() orelse return null;
        return .{ .kind = raw.kind, .span = .{
            .start = raw.start,
            .end = raw.end,
        } };
    }

    /// Core tokenizer: byte offsets are usize, never narrowed.
    pub fn nextRaw(self: *Tokenizer) ?RawToken {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.advance(),
                else => break,
            }
        }
        if (self.pos >= self.input.len) return null;

        const start = self.mark();
        switch (self.input[self.pos]) {
            '{' => return self.tokPunct(.object_begin, start),
            '}' => return self.tokPunct(.object_end, start),
            '[' => return self.tokPunct(.array_begin, start),
            ']' => return self.tokPunct(.array_end, start),
            ':' => return self.tokPunct(.colon, start),
            ',' => return self.tokPunct(.comma, start),
            '"' => return self.tokString(start),
            '/' => return self.tokComment(start),
            '-', '+', '.', '0'...'9' => return self.tokNumber(start),
            'A'...'Z', 'a'...'z', '_' => return self.tokKeyword(start),
            else => {
                self.advance();
                return self.token(.invalid, start);
            },
        }
    }

    fn tokPunct(self: *Tokenizer, kind: Kind, start: Mark) RawToken {
        self.advance();
        return self.token(kind, start);
    }

    fn tokString(self: *Tokenizer, start: Mark) RawToken {
        self.advance(); // opening quote
        while (self.pos < self.input.len) {
            const skipped = lex.scanStringFast(self.input[self.pos..]);
            self.pos += skipped;
            if (self.pos >= self.input.len) break;
            switch (self.input[self.pos]) {
                '"' => {
                    self.advance();
                    return self.token(.string, start);
                },
                '\\' => {
                    self.advance();
                    if (self.pos < self.input.len) self.advance();
                },
                // Raw control byte: invalid string content, but rejecting
                // it is the parser's job; we only find the bounds.
                else => self.advance(),
            }
        }
        return self.token(.invalid, start); // unterminated
    }

    fn tokNumber(self: *Tokenizer, start: Mark) RawToken {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                '-', '+', '.', 'e', 'E', '0'...'9' => self.advance(),
                else => break,
            }
        }
        const lexeme = self.input[start.pos..self.pos];
        return self.token(if (lex.isValidNumber(lexeme)) .number else .invalid, start);
    }

    fn tokKeyword(self: *Tokenizer, start: Mark) RawToken {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                'A'...'Z', 'a'...'z', '0'...'9', '_' => self.advance(),
                else => break,
            }
        }
        const lexeme = self.input[start.pos..self.pos];
        const kind: Kind = if (std.mem.eql(u8, lexeme, "true"))
            .literal_true
        else if (std.mem.eql(u8, lexeme, "false"))
            .literal_false
        else if (std.mem.eql(u8, lexeme, "null"))
            .literal_null
        else
            .invalid;
        return self.token(kind, start);
    }

    fn tokComment(self: *Tokenizer, start: Mark) RawToken {
        self.advance(); // leading `/`
        const ok: Kind = if (self.dialect == .jsonc) .comment else .invalid;
        if (self.pos >= self.input.len) return self.token(.invalid, start);
        switch (self.input[self.pos]) {
            '/' => {
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.advance();
                }
                return self.token(ok, start);
            },
            '*' => {
                self.advance();
                while (self.pos + 1 < self.input.len) {
                    if (self.input[self.pos] == '*' and self.input[self.pos + 1] == '/') {
                        self.advance();
                        self.advance();
                        return self.token(ok, start);
                    }
                    self.advance();
                }
                while (self.pos < self.input.len) self.advance();
                return self.token(.invalid, start); // unterminated
            },
            else => return self.token(.invalid, start),
        }
    }

    fn advance(self: *Tokenizer) void {
        self.pos += 1;
    }

    fn mark(self: *const Tokenizer) Mark {
        return .{ .pos = self.pos };
    }

    fn token(self: *const Tokenizer, kind: Kind, start: Mark) RawToken {
        return .{
            .kind = kind,
            .start = start.pos,
            .end = self.pos,
        };
    }
};

const testing = std.testing;

test "tokenize punctuation and literals" {
    var t: Tokenizer = .init("{ } [ ] : , true false null", .json);
    const kinds = [_]Kind{ .object_begin, .object_end, .array_begin, .array_end, .colon, .comma, .literal_true, .literal_false, .literal_null };
    for (kinds) |k| try testing.expectEqual(k, t.next().?.kind);
    try testing.expectEqual(@as(?Token, null), t.next());
}

test "tokenize string and number with spans" {
    var t: Tokenizer = .init("\"ab\" -12.5e3", .json);
    const s = t.next().?;
    try testing.expectEqual(Kind.string, s.kind);
    try testing.expectEqual(@as(u64, 0), s.span.start);
    try testing.expectEqual(@as(u64, 4), s.span.end);
    const n = t.next().?;
    try testing.expectEqual(Kind.number, n.kind);
}

test "tokenize error: bare garbage" {
    var t: Tokenizer = .init("@", .json);
    try testing.expectEqual(Kind.invalid, t.next().?.kind);
}

test "comments are invalid in strict json" {
    var t: Tokenizer = .init("// hi", .json);
    try testing.expectEqual(Kind.invalid, t.next().?.kind);
}

test "jsonc comments tokenize" {
    var t: Tokenizer = .init("// line\n/* block */ 1", .jsonc);
    try testing.expectEqual(Kind.comment, t.next().?.kind);
    try testing.expectEqual(Kind.comment, t.next().?.kind);
    try testing.expectEqual(Kind.number, t.next().?.kind);
}

test "spans track line and col across newlines (derived via lineCol)" {
    const src = "{\n  \"k\": 1\n}";
    var t: Tokenizer = .init(src, .json);

    const open = t.next().?;
    try testing.expectEqual(Kind.object_begin, open.kind);
    try testing.expectEqual(@as(u32, 1), open.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 1), open.span.lineCol(src).col);

    const key = t.next().?;
    try testing.expectEqual(Kind.string, key.kind);
    try testing.expectEqual(@as(u32, 2), key.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 3), key.span.lineCol(src).col);
    try testing.expectEqualStrings("\"k\"", src[key.span.start..key.span.end]);

    const colon = t.next().?;
    try testing.expectEqual(Kind.colon, colon.kind);
    try testing.expectEqual(@as(u32, 2), colon.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 6), colon.span.lineCol(src).col);

    const num = t.next().?;
    try testing.expectEqual(Kind.number, num.kind);
    try testing.expectEqual(@as(u32, 2), num.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 8), num.span.lineCol(src).col);

    const close = t.next().?;
    try testing.expectEqual(Kind.object_end, close.kind);
    try testing.expectEqual(@as(u32, 3), close.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 1), close.span.lineCol(src).col);

    try testing.expectEqual(@as(?Token, null), t.next());
}

test "escaped quote stays inside the string" {
    const src = "\"a\\\"b\"";
    var t: Tokenizer = .init(src, .json);
    const s = t.next().?;
    try testing.expectEqual(Kind.string, s.kind);
    try testing.expectEqual(@as(u64, 0), s.span.start);
    try testing.expectEqual(@as(u64, src.len), s.span.end);
    try testing.expectEqual(@as(?Token, null), t.next());
}

test "string longer than one simd block" {
    const src = "\"abcdefghijklmnopqrstuvwxyz0123456789\" 1";
    var t: Tokenizer = .init(src, .json);
    const s = t.next().?;
    try testing.expectEqual(Kind.string, s.kind);
    try testing.expectEqual(@as(u64, 38), s.span.end);
    const n = t.next().?;
    try testing.expectEqual(Kind.number, n.kind);
    try testing.expectEqual(@as(u32, 40), n.span.lineCol(src).col);
}

test "unterminated string is invalid to eof" {
    const src = "\"abc";
    var t: Tokenizer = .init(src, .json);
    const s = t.next().?;
    try testing.expectEqual(Kind.invalid, s.kind);
    try testing.expectEqual(@as(u64, 0), s.span.start);
    try testing.expectEqual(@as(u64, src.len), s.span.end);
    try testing.expectEqual(@as(?Token, null), t.next());
}

test "unterminated block comment is invalid to eof" {
    const src = "/* never closed";
    var t: Tokenizer = .init(src, .jsonc);
    const c = t.next().?;
    try testing.expectEqual(Kind.invalid, c.kind);
    try testing.expectEqual(@as(u64, 0), c.span.start);
    try testing.expectEqual(@as(u64, src.len), c.span.end);
    try testing.expectEqual(@as(?Token, null), t.next());
}

test "line comment span excludes the newline" {
    const src = "// hi\n1";
    var t: Tokenizer = .init(src, .jsonc);
    const c = t.next().?;
    try testing.expectEqual(Kind.comment, c.kind);
    try testing.expectEqual(@as(u64, 0), c.span.start);
    try testing.expectEqual(@as(u64, 5), c.span.end);
    const n = t.next().?;
    try testing.expectEqual(Kind.number, n.kind);
    try testing.expectEqual(@as(u32, 2), n.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 1), n.span.lineCol(src).col);
}

test "number grammar rejects malformed lexemes" {
    const rejects = [_][]const u8{ "01", ".5", "1.", "+1", "1e", "-", "1e+", "1.e3", "--1" };
    for (rejects) |src| {
        var t: Tokenizer = .init(src, .json);
        const tok = t.next().?;
        try testing.expectEqual(Kind.invalid, tok.kind);
        try testing.expectEqual(@as(u64, 0), tok.span.start);
        try testing.expectEqual(@as(u64, src.len), tok.span.end);
        try testing.expectEqual(@as(?Token, null), t.next());
    }
}

test "number grammar accepts valid lexemes" {
    const accepts = [_][]const u8{ "0", "-0", "1e+10", "0.5E-3", "-12.5e3", "123", "0.0" };
    for (accepts) |src| {
        var t: Tokenizer = .init(src, .json);
        const tok = t.next().?;
        try testing.expectEqual(Kind.number, tok.kind);
        try testing.expectEqual(@as(u64, 0), tok.span.start);
        try testing.expectEqual(@as(u64, src.len), tok.span.end);
        try testing.expectEqual(@as(?Token, null), t.next());
    }
}

test "keyword with trailing identifier chars is invalid" {
    var t: Tokenizer = .init("truex", .json);
    const tok = t.next().?;
    try testing.expectEqual(Kind.invalid, tok.kind);
    try testing.expectEqual(@as(u64, 0), tok.span.start);
    try testing.expectEqual(@as(u64, 5), tok.span.end);
    try testing.expectEqual(@as(?Token, null), t.next());
}

test "slash runs are single invalid tokens in strict json" {
    var line: Tokenizer = .init("/* block */ 1", .json);
    const c = line.next().?;
    try testing.expectEqual(Kind.invalid, c.kind);
    try testing.expectEqual(@as(u64, 0), c.span.start);
    try testing.expectEqual(@as(u64, 11), c.span.end);
    try testing.expectEqual(Kind.number, line.next().?.kind);

    var bare: Tokenizer = .init("/ 1", .json);
    const b = bare.next().?;
    try testing.expectEqual(Kind.invalid, b.kind);
    try testing.expectEqual(@as(u64, 1), b.span.end);
    try testing.expectEqual(Kind.number, bare.next().?.kind);
}

test "bare slash is invalid in jsonc too" {
    var t: Tokenizer = .init("/ 1", .jsonc);
    try testing.expectEqual(Kind.invalid, t.next().?.kind);
    try testing.expectEqual(Kind.number, t.next().?.kind);
}

test "simd vector window finds the closing quote" {
    // After the opening quote, 17 bytes remain, so the first full
    // 16-byte vector window covers the closing quote at offset 3.
    const src = "\"abc\"" ++ " " ** 12 ++ "1";
    var t: Tokenizer = .init(src, .json);
    const s = t.next().?;
    try testing.expectEqual(Kind.string, s.kind);
    try testing.expectEqual(@as(u64, 5), s.span.end);
    const n = t.next().?;
    try testing.expectEqual(Kind.number, n.kind);
    try testing.expectEqual(@as(u32, 18), n.span.lineCol(src).col);
}

test "simd vector window finds a backslash first" {
    // After the opening quote, 20 bytes remain; the first vector window
    // stops on the backslash at offset 2, not the escaped quote.
    const src = "\"ab\\\"cd\"" ++ " " ** 12 ++ "1";
    var t: Tokenizer = .init(src, .json);
    const s = t.next().?;
    try testing.expectEqual(Kind.string, s.kind);
    try testing.expectEqual(@as(u64, 8), s.span.end);
    const n = t.next().?;
    try testing.expectEqual(Kind.number, n.kind);
    try testing.expectEqual(@as(u32, 21), n.span.lineCol(src).col);
}

test "line comment span includes a trailing CR before LF" {
    const src = "// hi\r\n1";
    var t: Tokenizer = .init(src, .jsonc);
    const c = t.next().?;
    try testing.expectEqual(Kind.comment, c.kind);
    try testing.expectEqualStrings("// hi\r", src[c.span.start..c.span.end]);
    const n = t.next().?;
    try testing.expectEqual(Kind.number, n.kind);
    try testing.expectEqual(@as(u32, 2), n.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 1), n.span.lineCol(src).col);
}

test "lone CR between tokens does not increment line" {
    const src = "1\r2";
    var t: Tokenizer = .init(src, .json);
    const a = t.next().?;
    try testing.expectEqual(Kind.number, a.kind);
    try testing.expectEqual(@as(u32, 1), a.span.lineCol(src).line);
    const b = t.next().?;
    try testing.expectEqual(Kind.number, b.kind);
    try testing.expectEqual(@as(u32, 1), b.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 3), b.span.lineCol(src).col);
}

test "multiline block comment tracks line and col" {
    const src = "/* a\nb\nc */ 1";
    var t: Tokenizer = .init(src, .jsonc);
    const c = t.next().?;
    try testing.expectEqual(Kind.comment, c.kind);
    try testing.expectEqual(@as(u32, 1), c.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 1), c.span.lineCol(src).col);
    const n = t.next().?;
    try testing.expectEqual(Kind.number, n.kind);
    try testing.expectEqual(@as(u32, 3), n.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 6), n.span.lineCol(src).col);
}

test "escape at eof is invalid to eof" {
    const src = "\"a\\";
    var t: Tokenizer = .init(src, .json);
    const s = t.next().?;
    try testing.expectEqual(Kind.invalid, s.kind);
    try testing.expectEqual(@as(u64, 0), s.span.start);
    try testing.expectEqual(@as(u64, src.len), s.span.end);
    try testing.expectEqual(@as(?Token, null), t.next());
}
