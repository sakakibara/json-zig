//! Conformance harness over vendored fixture corpora.
//!
//! `tests/corpus/JSONTestSuite/` vendors the `test_parsing/` fixtures of
//! https://github.com/nst/JSONTestSuite (see LICENSE alongside them):
//!
//! - `y_*.json` must parse (in both `.json` and `.jsonc`; jsonc is a
//!   strict superset).
//! - `n_*.json` must fail to parse in `.json`.
//! - `i_*.json` are implementation-defined; every file is pinned to an
//!   explicit accept/reject decision in `i_policy` below, and a fixture
//!   missing from the table is a harness error so corpus updates force
//!   conscious decisions.
//!
//! `tests/corpus/jsonc/` is this project's own corpus for the JSONC
//! dialect extensions (comments, trailing commas).
//!
//! Fixtures are discovered at test time via std.fs; the corpus root is
//! injected by build.zig as the `corpus_path` build option, so the suite
//! works from any cwd. The parser's depth cap plus single-pass design
//! bound every fixture; no timeout machinery is needed.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const json = @import("json.zig");
const conformance_options = @import("conformance_options");

/// Fixture size sanity bound. The largest JSONTestSuite file is ~250 KB;
/// anything over 1 MB indicates a corrupted or mis-vendored corpus.
const max_fixture_bytes: usize = 1 << 20;

/// Expected fixture counts, pinned so silent corpus drift (lost or extra
/// files) fails the suite.
const expected_y: usize = 95;
const expected_n: usize = 188;
const expected_i: usize = 35;
const expected_jsonc_y: usize = 6;
const expected_jsonc_n: usize = 3;

const Policy = enum { accept, reject };

const PolicyEntry = struct {
    name: []const u8,
    policy: Policy,
};

/// Decision for every i_ fixture in the vendored corpus. Grouped by the
/// parser behavior that decides them:
///
/// - Numbers beyond i128/f64 precision or range: ACCEPT. Integer-syntax
///   lexemes that overflow i128 fall back to f64; huge exponents resolve
///   to +/-inf or 0.0 via std.fmt.parseFloat. Parsing never fails on a
///   grammatically valid number.
/// - Invalid UTF-8 byte sequences inside strings: REJECT. The parser
///   validates string content as UTF-8 strictly (overlong encodings,
///   continuation-byte garbage, raw encoded surrogates, Latin-1 bytes
///   all fail). This diverges from implementations that pass raw bytes
///   through; the strictness is the shipped policy.
/// - Lone / mismatched surrogates in \u escapes: REJECT. Escapes must
///   form valid scalar values; unpaired surrogates are errors.
/// - UTF-16 encoded files (with or without BOM): REJECT. Input must be
///   UTF-8; UTF-16 code units lex as invalid tokens.
/// - UTF-8 BOM: REJECT. The parser does not skip a leading BOM; input
///   must start with a JSON token.
/// - 500 nested arrays: REJECT via error.NestingTooDeep (default
///   max_depth 128 guards the stack).
const i_policy = [_]PolicyEntry{
    // numbers: f64 fallback handles overflow/underflow/precision loss
    .{ .name = "i_number_double_huge_neg_exp.json", .policy = .accept },
    .{ .name = "i_number_huge_exp.json", .policy = .accept },
    .{ .name = "i_number_neg_int_huge_exp.json", .policy = .accept },
    .{ .name = "i_number_pos_double_huge_exp.json", .policy = .accept },
    .{ .name = "i_number_real_neg_overflow.json", .policy = .accept },
    .{ .name = "i_number_real_pos_overflow.json", .policy = .accept },
    .{ .name = "i_number_real_underflow.json", .policy = .accept },
    .{ .name = "i_number_too_big_neg_int.json", .policy = .accept },
    .{ .name = "i_number_too_big_pos_int.json", .policy = .accept },
    .{ .name = "i_number_very_big_negative_int.json", .policy = .accept },
    // lone / mismatched surrogates in \u escapes
    .{ .name = "i_object_key_lone_2nd_surrogate.json", .policy = .reject },
    .{ .name = "i_string_1st_surrogate_but_2nd_missing.json", .policy = .reject },
    .{ .name = "i_string_1st_valid_surrogate_2nd_invalid.json", .policy = .reject },
    .{ .name = "i_string_incomplete_surrogate_and_escape_valid.json", .policy = .reject },
    .{ .name = "i_string_incomplete_surrogate_pair.json", .policy = .reject },
    .{ .name = "i_string_incomplete_surrogates_escape_valid.json", .policy = .reject },
    .{ .name = "i_string_invalid_lonely_surrogate.json", .policy = .reject },
    .{ .name = "i_string_invalid_surrogate.json", .policy = .reject },
    .{ .name = "i_string_inverted_surrogates_U+1D11E.json", .policy = .reject },
    .{ .name = "i_string_lone_second_surrogate.json", .policy = .reject },
    // invalid UTF-8 byte sequences in string content
    .{ .name = "i_string_UTF-8_invalid_sequence.json", .policy = .reject },
    .{ .name = "i_string_UTF8_surrogate_U+D800.json", .policy = .reject },
    .{ .name = "i_string_invalid_utf-8.json", .policy = .reject },
    .{ .name = "i_string_iso_latin_1.json", .policy = .reject },
    .{ .name = "i_string_lone_utf8_continuation_byte.json", .policy = .reject },
    .{ .name = "i_string_not_in_unicode_range.json", .policy = .reject },
    .{ .name = "i_string_overlong_sequence_2_bytes.json", .policy = .reject },
    .{ .name = "i_string_overlong_sequence_6_bytes.json", .policy = .reject },
    .{ .name = "i_string_overlong_sequence_6_bytes_null.json", .policy = .reject },
    .{ .name = "i_string_truncated-utf-8.json", .policy = .reject },
    // UTF-16 encoded input (parser reads UTF-8 only)
    .{ .name = "i_string_UTF-16LE_with_BOM.json", .policy = .reject },
    .{ .name = "i_string_utf16BE_no_BOM.json", .policy = .reject },
    .{ .name = "i_string_utf16LE_no_BOM.json", .policy = .reject },
    // structure: 500 levels rejected by the depth cap; BOM rejected by the lexer
    .{ .name = "i_structure_500_nested_arrays.json", .policy = .reject },
    .{ .name = "i_structure_UTF-8_BOM_empty_object.json", .policy = .reject },
};

fn lookupPolicy(name: []const u8) ?Policy {
    for (i_policy) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.policy;
    }
    return null;
}

/// True when `src` parses cleanly in `dialect`. Parse failures
/// (JsonParseError, NestingTooDeep) map to false; OutOfMemory propagates
/// as a real test error.
fn parses(src: []const u8, dialect: json.Dialect) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = json.parse(arena.allocator(), src, .{ .dialect = dialect }) catch |err| switch (err) {
        error.JsonParseError, error.NestingTooDeep => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return true;
}

/// Deep structural equality between two parsed trees; test-only helper
/// for the corpus round-trip assertions.
///
/// Comparison policy:
/// - The numeric tag matters: integer 1 never equals float 1.0 (the
///   parser keeps the distinction and the encoder preserves it).
/// - Integers compare exactly with `==`.
/// - Floats compare bit-for-bit via @bitCast: -0.0 and 0.0 are NOT
///   equal (different sign bit). The encoder's shortest-round-trip
///   notation reproduces exact bits, so the round-trip must hold under
///   this strictness; anything looser could mask a lossy re-parse.
/// - Objects compare key ORDER as well as content: ObjectMap is
///   insertion-ordered and encode emits members in that order, so a
///   lossless round-trip must reproduce the exact member sequence.
fn valueEql(a: json.Value, b: json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .null => return true,
        .bool => |x| return x == b.bool,
        .integer => |x| return x == b.integer,
        .float => |x| return @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.float)),
        .number_raw => |x| return std.mem.eql(u8, x, b.number_raw),
        .string => |x| return std.mem.eql(u8, x, b.string),
        .array => |x| {
            if (x.len != b.array.len) return false;
            for (x, b.array) |ea, eb| {
                if (!valueEql(ea, eb)) return false;
            }
            return true;
        },
        .object => |x| {
            if (x.count() != b.object.count()) return false;
            for (x.keys(), b.object.keys()) |ka, kb| {
                if (!std.mem.eql(u8, ka, kb)) return false;
            }
            for (x.values(), b.object.values()) |va, vb| {
                if (!valueEql(va, vb)) return false;
            }
            return true;
        },
    }
}

/// True when `src` survives parse -> encode -> parse with a deeply
/// equal tree. The encoder emits strict JSON regardless of the input
/// dialect, so the second parse always uses `.json`.
fn roundTrips(src: []const u8, dialect: json.Dialect) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try json.parse(a, src, .{ .dialect = dialect });
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    json.encode(&aw.writer, first) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.UnrepresentableFloat, error.NestingTooDeep => return false,
    };
    const second = try json.parse(a, aw.written(), .{});
    return valueEql(first, second);
}

/// True when `Document.parse` + `emit` reproduces `src` byte-for-byte.
/// A parse failure counts as not-lossless so the caller names the
/// fixture; OutOfMemory propagates as a real test error.
fn emitsLosslessly(src: []const u8, dialect: json.Dialect) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = json.Document.parse(a, src, .{ .dialect = dialect }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    doc.emit(&aw.writer) catch return error.OutOfMemory;
    return std.mem.eql(u8, src, aw.written());
}

fn openCorpusDir(io: Io, comptime sub: []const u8) !Io.Dir {
    const path = conformance_options.corpus_path ++ "/" ++ sub;
    return Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
}

fn readFixture(io: Io, a: std.mem.Allocator, dir: Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(io, name, a, .limited(max_fixture_bytes)) catch |err| {
        std.debug.print("conformance: cannot read fixture '{s}': {t}\n", .{ name, err });
        return err;
    };
}

test "JSONTestSuite: y_ fixtures parse in .json and .jsonc" {
    const io = testing.io;
    var dir = try openCorpusDir(io, "JSONTestSuite");
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "y_")) continue;
        count += 1;
        const src = try readFixture(io, testing.allocator, dir, entry.name);
        defer testing.allocator.free(src);
        if (!try parses(src, .json)) {
            std.debug.print("conformance: y_ fixture failed to parse (.json): {s}\n", .{entry.name});
            failures += 1;
        }
        if (!try parses(src, .jsonc)) {
            std.debug.print("conformance: y_ fixture failed to parse (.jsonc): {s}\n", .{entry.name});
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(expected_y, count);
}

test "JSONTestSuite: n_ fixtures fail to parse in .json" {
    const io = testing.io;
    var dir = try openCorpusDir(io, "JSONTestSuite");
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "n_")) continue;
        count += 1;
        const src = try readFixture(io, testing.allocator, dir, entry.name);
        defer testing.allocator.free(src);
        if (try parses(src, .json)) {
            std.debug.print("conformance: n_ fixture parsed but must fail: {s}\n", .{entry.name});
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(expected_n, count);
}

test "JSONTestSuite: i_ fixtures match the policy table" {
    const io = testing.io;
    var dir = try openCorpusDir(io, "JSONTestSuite");
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "i_")) continue;
        count += 1;
        const policy = lookupPolicy(entry.name) orelse {
            std.debug.print("conformance: i_ fixture missing from i_policy table: {s}\n", .{entry.name});
            failures += 1;
            continue;
        };
        const src = try readFixture(io, testing.allocator, dir, entry.name);
        defer testing.allocator.free(src);
        const ok = try parses(src, .json);
        switch (policy) {
            .accept => if (!ok) {
                std.debug.print("conformance: i_ fixture rejected but policy says accept: {s}\n", .{entry.name});
                failures += 1;
            },
            .reject => if (ok) {
                std.debug.print("conformance: i_ fixture accepted but policy says reject: {s}\n", .{entry.name});
                failures += 1;
            },
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    // Both directions of drift: every file on disk has a table entry
    // (checked above), and the table has no stale entries for files
    // that no longer exist (count == table length == pinned total).
    try testing.expectEqual(expected_i, count);
    try testing.expectEqual(expected_i, i_policy.len);
}

test "jsonc corpus: y_ parses in .jsonc, n_ fails in .jsonc" {
    const io = testing.io;
    var dir = try openCorpusDir(io, "jsonc");
    defer dir.close(io);

    var y_count: usize = 0;
    var n_count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const src = try readFixture(io, testing.allocator, dir, entry.name);
        defer testing.allocator.free(src);
        if (std.mem.startsWith(u8, entry.name, "y_")) {
            y_count += 1;
            if (!try parses(src, .jsonc)) {
                std.debug.print("conformance: jsonc y_ fixture failed to parse (.jsonc): {s}\n", .{entry.name});
                failures += 1;
            }
        } else if (std.mem.startsWith(u8, entry.name, "n_")) {
            n_count += 1;
            if (try parses(src, .jsonc)) {
                std.debug.print("conformance: jsonc n_ fixture parsed but must fail (.jsonc): {s}\n", .{entry.name});
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(expected_jsonc_y, y_count);
    try testing.expectEqual(expected_jsonc_n, n_count);
}

test "jsonc corpus: strict .json rejects every y_ except y_slashes_in_string" {
    const io = testing.io;
    var dir = try openCorpusDir(io, "jsonc");
    defer dir.close(io);

    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "y_")) continue;
        const src = try readFixture(io, testing.allocator, dir, entry.name);
        defer testing.allocator.free(src);
        // `//` inside a string literal is content, not a comment: that
        // fixture is plain JSON and must pass in both dialects. Every
        // other y_ fixture exercises a JSONC-only extension and must
        // fail in strict .json.
        const expect_ok = std.mem.eql(u8, entry.name, "y_slashes_in_string.jsonc");
        const ok = try parses(src, .json);
        if (ok != expect_ok) {
            std.debug.print("conformance: jsonc y_ fixture wrong strict-.json result (got {}, want {}): {s}\n", .{ ok, expect_ok, entry.name });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "JSONTestSuite: y_ fixtures round-trip parse -> encode -> parse" {
    const io = testing.io;
    var dir = try openCorpusDir(io, "JSONTestSuite");
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "y_")) continue;
        count += 1;
        const src = try readFixture(io, testing.allocator, dir, entry.name);
        defer testing.allocator.free(src);
        if (!try roundTrips(src, .json)) {
            std.debug.print("conformance: y_ fixture does not round-trip (.json): {s}\n", .{entry.name});
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(expected_y, count);
}

test "JSONTestSuite: y_ fixtures emit byte-identically through Document" {
    const io = testing.io;
    var dir = try openCorpusDir(io, "JSONTestSuite");
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "y_")) continue;
        count += 1;
        const src = try readFixture(io, testing.allocator, dir, entry.name);
        defer testing.allocator.free(src);
        if (!try emitsLosslessly(src, .json)) {
            std.debug.print("conformance: y_ fixture not byte-identical through Document (.json): {s}\n", .{entry.name});
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(expected_y, count);
}

test "jsonc corpus: y_ fixtures round-trip parse -> encode -> parse" {
    const io = testing.io;
    var dir = try openCorpusDir(io, "jsonc");
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "y_")) continue;
        count += 1;
        const src = try readFixture(io, testing.allocator, dir, entry.name);
        defer testing.allocator.free(src);
        if (!try roundTrips(src, .jsonc)) {
            std.debug.print("conformance: jsonc y_ fixture does not round-trip (.jsonc): {s}\n", .{entry.name});
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(expected_jsonc_y, count);
}

test "jsonc corpus: y_ fixtures emit byte-identically through Document" {
    const io = testing.io;
    var dir = try openCorpusDir(io, "jsonc");
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "y_")) continue;
        count += 1;
        const src = try readFixture(io, testing.allocator, dir, entry.name);
        defer testing.allocator.free(src);
        if (!try emitsLosslessly(src, .jsonc)) {
            std.debug.print("conformance: jsonc y_ fixture not byte-identical through Document (.jsonc): {s}\n", .{entry.name});
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(expected_jsonc_y, count);
}

test "fixture size sanity bound" {
    const io = testing.io;
    inline for (.{ "JSONTestSuite", "jsonc" }) |sub| {
        var dir = try openCorpusDir(io, sub);
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const st = try dir.statFile(io, entry.name, .{});
            if (st.size >= max_fixture_bytes) {
                std.debug.print("conformance: fixture exceeds size bound: {s}/{s} ({d} bytes)\n", .{ sub, entry.name, st.size });
                return error.FixtureTooLarge;
            }
        }
    }
}

/// Parse `src` via EventReader and materialize the single top-level value into
/// `arena`. Returns the Value on success, or an error if the stream rejects
/// the input. Trailing non-whitespace after the value is treated as a reject:
/// after materialize() the next event must be end_of_input.
fn streamParse(arena: std.mem.Allocator, src: []const u8, dialect: json.Dialect) !json.Value {
    var r: std.Io.Reader = .fixed(src);
    var er = json.EventReader.fromReader(arena, &r, .{ .dialect = dialect });
    defer er.deinit();

    // Prime to the first event.
    const first = (try er.next()) orelse return error.JsonParseError;
    switch (first.kind) {
        .end_of_input => return error.JsonParseError, // empty input
        .object_begin, .array_begin, .string, .number, .boolean, .null => {},
        else => return error.JsonParseError,
    }

    const v = try er.materialize(arena);

    // Require end_of_input immediately after the value; trailing garbage is a reject.
    const trailing = (try er.next()) orelse return error.JsonParseError;
    if (trailing.kind != .end_of_input) return error.JsonParseError;

    return v;
}

test "JSONTestSuite: streaming agrees with the tree parser" {
    const io = testing.io;
    var dir = try openCorpusDir(io, "JSONTestSuite");
    defer dir.close(io);

    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;

        // Determine expected policy from filename prefix.
        const policy: Policy = if (std.mem.startsWith(u8, entry.name, "y_"))
            .accept
        else if (std.mem.startsWith(u8, entry.name, "n_"))
            .reject
        else if (std.mem.startsWith(u8, entry.name, "i_"))
            lookupPolicy(entry.name) orelse {
                std.debug.print("conformance/stream: i_ fixture missing from i_policy table: {s}\n", .{entry.name});
                failures += 1;
                continue;
            }
        else
            continue; // skip non-fixture files (e.g. LICENSE)

        const src = try readFixture(io, testing.allocator, dir, entry.name);
        defer testing.allocator.free(src);

        // Per-fixture arena keeps memory bounded.
        var fixture_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer fixture_arena.deinit();
        const a = fixture_arena.allocator();

        switch (policy) {
            .accept => {
                // Tree parser must accept (existing test already verifies this;
                // here we additionally require streaming to accept and agree).
                const tree_v = json.parse(a, src, .{}) catch |err| {
                    std.debug.print("conformance/stream: accept fixture tree-parse failed ({t}): {s}\n", .{ err, entry.name });
                    failures += 1;
                    continue;
                };
                const stream_v = streamParse(a, src, .json) catch |err| {
                    std.debug.print("conformance/stream: accept fixture stream-parse failed ({t}): {s}\n", .{ err, entry.name });
                    failures += 1;
                    continue;
                };
                if (!valueEql(tree_v, stream_v)) {
                    std.debug.print("conformance/stream: accept fixture values differ between tree and stream: {s}\n", .{entry.name});
                    failures += 1;
                }
            },
            .reject => {
                // Streaming must also reject.
                const stream_result = streamParse(a, src, .json);
                if (!isError(stream_result)) {
                    std.debug.print("conformance/stream: reject fixture streamed successfully but must fail: {s}\n", .{entry.name});
                    failures += 1;
                }
            },
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

/// True when `result` holds an error rather than a value.
fn isError(result: anytype) bool {
    if (result) |_| return false else |_| return true;
}
