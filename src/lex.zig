//! Shared lexical predicates for the buffered tokenizer and the streaming
//! scanner, plus the JSON string-unescape core used by every decoder.

const std = @import("std");

/// Fine-grained unescape failure. Callers map these to their own error
/// values and diagnostic messages.
pub const UnescapeError = error{
    TruncatedEscape,
    InvalidEscape,
    InvalidCodepoint,
    TruncatedUnicodeEscape,
    InvalidHexDigit,
    LoneLowSurrogate,
    UnpairedHighSurrogate,
    ControlCharacter,
    InvalidUtf8,
} || std.mem.Allocator.Error;

/// Decode JSON string escapes from `content` (the bytes between the
/// quotes) into `out`, including surrogate-pair combination in `\u`
/// escapes. With `validate`, non-escape bytes are checked for raw control
/// characters and UTF-8 validity byte-by-byte; without it, runs between
/// escapes are copied verbatim (for callers whose input is pre-validated).
pub fn unescape(
    comptime validate: bool,
    allocator: std.mem.Allocator,
    content: []const u8,
    out: *std.ArrayList(u8),
) UnescapeError!void {
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '\\') {
            i += 1;
            if (i >= content.len) return error.TruncatedEscape;
            const e = content[i];
            i += 1;
            switch (e) {
                '"' => try out.append(allocator, '"'),
                '\\' => try out.append(allocator, '\\'),
                '/' => try out.append(allocator, '/'),
                'b' => try out.append(allocator, 0x08),
                'f' => try out.append(allocator, 0x0C),
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                't' => try out.append(allocator, '\t'),
                'u' => {
                    const cp = try decodeUnicodeEscape(content, &i);
                    var utf8: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &utf8) catch return error.InvalidCodepoint;
                    try out.appendSlice(allocator, utf8[0..n]);
                },
                else => return error.InvalidEscape,
            }
        } else if (validate) {
            if (c < 0x20) return error.ControlCharacter;
            if (c < 0x80) {
                try out.append(allocator, c);
                i += 1;
            } else {
                const len = std.unicode.utf8ByteSequenceLength(c) catch return error.InvalidUtf8;
                if (i + len > content.len) return error.InvalidUtf8;
                _ = std.unicode.utf8Decode(content[i .. i + len]) catch return error.InvalidUtf8;
                try out.appendSlice(allocator, content[i .. i + len]);
                i += len;
            }
        } else {
            const run_end = std.mem.indexOfScalarPos(u8, content, i, '\\') orelse content.len;
            try out.appendSlice(allocator, content[i..run_end]);
            i = run_end;
        }
    }
}

/// Decode a `\uXXXX` escape; `i` points just past the `u`. A high
/// surrogate must be followed by a `\uXXXX` low surrogate, which combines
/// into one codepoint; lone surrogates of either kind are errors.
fn decodeUnicodeEscape(content: []const u8, i: *usize) UnescapeError!u21 {
    const hi = try parseHex4(content, i);
    if (hi >= 0xDC00 and hi <= 0xDFFF) return error.LoneLowSurrogate;
    if (hi < 0xD800 or hi > 0xDBFF) return hi;
    if (i.* + 2 > content.len or content[i.*] != '\\' or content[i.* + 1] != 'u') {
        return error.UnpairedHighSurrogate;
    }
    i.* += 2;
    const lo = try parseHex4(content, i);
    if (lo < 0xDC00 or lo > 0xDFFF) return error.UnpairedHighSurrogate;
    return 0x10000 + (@as(u21, hi - 0xD800) << 10) + (lo - 0xDC00);
}

/// Parse four hex digits from `buf` at `i`, advance `i` by 4.
fn parseHex4(buf: []const u8, i: *usize) UnescapeError!u16 {
    if (i.* + 4 > buf.len) return error.TruncatedUnicodeEscape;
    var cp: u16 = 0;
    for (buf[i.*..][0..4]) |c| {
        const d: u16 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidHexDigit,
        };
        cp = cp * 16 + d;
    }
    i.* += 4;
    return cp;
}

/// Skip ASCII bytes that need no special handling inside a string (not
/// `"`, `\`, or a control byte < 0x20). Returns the count skipped; the
/// caller handles the byte at the returned offset (or hits the slice end).
pub fn scanStringFast(bytes: []const u8) usize {
    const W = 16;
    var i: usize = 0;
    const quote: @Vector(W, u8) = @splat('"');
    const backslash: @Vector(W, u8) = @splat('\\');
    const ctrl_max: @Vector(W, u8) = @splat(0x1f);
    while (i + W <= bytes.len) {
        const chunk: @Vector(W, u8) = bytes[i..][0..W].*;
        const stop = (chunk == quote) | (chunk == backslash) | (chunk <= ctrl_max);
        const mask: u16 = @bitCast(stop);
        if (mask != 0) return i + @ctz(mask);
        i += W;
    }
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '"' or c == '\\' or c < 0x20) return i;
        i += 1;
    }
    return i;
}

/// Validate a complete lexeme against the RFC 8259 number grammar:
/// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
pub fn isValidNumber(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    if (i >= s.len or !isDigit(s[i])) return false;
    if (s[i] == '0') {
        i += 1;
    } else {
        while (i < s.len and isDigit(s[i])) i += 1;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i >= s.len or !isDigit(s[i])) return false;
        while (i < s.len and isDigit(s[i])) i += 1;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        if (i >= s.len or !isDigit(s[i])) return false;
        while (i < s.len and isDigit(s[i])) i += 1;
    }
    return i == s.len;
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub const NumberClass = enum { sign, dot, exp, digit, other };

pub fn classifyNumberByte(c: u8) NumberClass {
    return switch (c) {
        '-', '+' => .sign,
        '.' => .dot,
        'e', 'E' => .exp,
        '0'...'9' => .digit,
        else => .other,
    };
}

test "isValidNumber accepts and rejects per RFC 8259" {
    const ok = [_][]const u8{ "0", "-0", "1e+10", "0.5E-3", "-12.5e3", "123" };
    for (ok) |s| try std.testing.expect(isValidNumber(s));
    const bad = [_][]const u8{ "01", ".5", "1.", "+1", "1e", "-", "1e+", "--1" };
    for (bad) |s| try std.testing.expect(!isValidNumber(s));
}

test "scanStringFast stops at quote, backslash, or control" {
    try std.testing.expectEqual(@as(usize, 3), scanStringFast("abc\"de"));
    try std.testing.expectEqual(@as(usize, 2), scanStringFast("ab\\c"));
    try std.testing.expectEqual(@as(usize, 5), scanStringFast("plain"));
}

test "unescape decodes escapes and surrogate pairs in both modes" {
    const a = std.testing.allocator;
    inline for (.{ true, false }) |validate| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try unescape(validate, a, "a\\n\\u0041\\uD83D\\uDE00b", &out);
        try std.testing.expectEqualStrings("a\nA\xF0\x9F\x98\x80b", out.items);
    }
}

test "unescape failure codes" {
    const a = std.testing.allocator;
    const cases = .{
        .{ "x\\", error.TruncatedEscape },
        .{ "\\q", error.InvalidEscape },
        .{ "\\u00", error.TruncatedUnicodeEscape },
        .{ "\\u00zz", error.InvalidHexDigit },
        .{ "\\uDE00", error.LoneLowSurrogate },
        .{ "\\uD83Dx", error.UnpairedHighSurrogate },
        .{ "\\uD83D\\u0041", error.UnpairedHighSurrogate },
    };
    inline for (cases) |case| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try std.testing.expectError(case[1], unescape(true, a, case[0], &out));
    }
    // Raw-byte validation only fires in validate mode.
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try std.testing.expectError(error.ControlCharacter, unescape(true, a, "\x01", &out));
        out.clearRetainingCapacity();
        try std.testing.expectError(error.InvalidUtf8, unescape(true, a, "\xff", &out));
        out.clearRetainingCapacity();
        try unescape(false, a, "\x01\xff", &out);
        try std.testing.expectEqualStrings("\x01\xff", out.items);
    }
}
