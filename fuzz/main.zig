//! Bounded random-input fuzzer.
//!
//! Mutates a set of valid JSON/JSONC seed documents (byte flips, inserts,
//! deletes, truncation, splices) and also throws fully random byte strings
//! at the parser. Every iteration is bounded: inputs are capped at 64 KB
//! and the parser is single-pass with a nesting-depth cap, so no timeout
//! machinery is needed.
//!
//! Checked invariants per input, in both dialects:
//!
//! 1. `parse` returns a value or a parse error; it never crashes. An
//!    errors sink is attached on a coin flip to exercise recovery paths.
//! 2. If `parse` succeeds, `encode` succeeds (`UnrepresentableFloat` is
//!    allowed: huge exponents parse to +/-inf, which JSON cannot emit)
//!    and re-parsing the encoded output yields a deeply equal tree.
//! 3. `Document.parse` succeeds exactly when `parse` does, and a parsed
//!    document emits its input byte-for-byte.
//!
//! Usage: `zig build fuzz -- [seed] [iterations]`. Defaults are fixed, so
//! plain `zig build fuzz` is deterministic; a reported failure prints the
//! seed and iteration needed to reproduce it.

const std = @import("std");
const json = @import("json");

const default_seed: u64 = 0x6a736f6e2d7a6967; // "json-zig"
const default_iterations: usize = 10_000;
const max_input_bytes: usize = 64 * 1024;

/// Valid documents covering the whole surface syntax: nested containers,
/// every escape form, integer/float edge values, and (for the JSONC
/// entries) comments and trailing commas. Mutation starts from these so
/// random edits land near interesting grammar.
const seed_docs = [_][]const u8{
    \\{"name":"agent","server":{"host":"::1","port":8443,"tls":{"enabled":true,"paths":["/a","/b"]}},"tags":["x","y"],"empty_obj":{},"empty_arr":[],"flag":null}
    ,
    \\{"escapes":"quote:\" back:\\ slash:\/ bs:\b ff:\f nl:\n cr:\r tab:\t nul:\u0000 e:\u00e9 pair:\ud83d\ude00 raw:é😀"}
    ,
    \\[0,-0,-0.0,1.5,-2.5e-3,1e10,1E-10,123.456,9223372036854775807,-9223372036854775808,1e999,-1e999,5e-324,1.7976931348623157e308]
    ,
    \\[[[[[[[[["deep"]]]]]]]],{"a":{"b":{"c":{"d":[true,false,null]}}}},""]
    ,
    \\// line comment
    \\{
    \\  "jsonc": true, /* block
    \\     comment */ "trailing": [1, 2, 3,],
    \\  "last": {"k": "v",},
    \\}
    ,
    \\{"":"empty key","a.b":"dotted key","\u0041":"escaped key","dup":1,"dup":2}
};

const Random = std.Random;

var input_buf: [max_input_bytes]u8 = undefined;
var splice_buf: [max_input_bytes]u8 = undefined;
var large_json_buf: [64 * 1024]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var seed: u64 = default_seed;
    var iterations: usize = default_iterations;
    if (argv.len > 1) seed = std.fmt.parseInt(u64, argv[1], 0) catch {
        std.debug.print("fuzz: bad seed '{s}' (want integer)\n", .{argv[1]});
        std.process.exit(2);
    };
    if (argv.len > 2) iterations = std.fmt.parseInt(usize, argv[2], 0) catch {
        std.debug.print("fuzz: bad iteration count '{s}' (want integer)\n", .{argv[2]});
        std.process.exit(2);
    };

    var prng = Random.DefaultPrng.init(seed);
    const random = prng.random();

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        defer _ = arena_state.reset(.retain_capacity);
        const input = generateInput(random);
        checkInput(arena_state.allocator(), random, input) catch |err| {
            std.debug.print(
                "\nfuzz FAILURE: {t}\n  seed: 0x{x}\n  iteration: {d}\n  input ({d} bytes): ",
                .{ err, seed, iter, input.len },
            );
            printEscaped(input);
            std.debug.print("\n", .{});
            std.process.exit(1);
        };

        // Dedicated large-input arm: always exceeds the 4096-byte pull chunk so
        // pull() fires more than once per document, exercising multi-pull resumption.
        const large = generateLargeJson(random);
        const large_parsed: ?json.Value = json.parse(arena_state.allocator(), large, .{}) catch |err| switch (err) {
            error.JsonParseError, error.NestingTooDeep => null,
            error.OutOfMemory => {
                std.debug.print(
                    "\nfuzz FAILURE: OutOfMemory\n  seed: 0x{x}\n  iteration: {d}\n",
                    .{ seed, iter },
                );
                std.process.exit(1);
            },
        };
        checkReaderStream(arena_state.allocator(), large, .json, large_parsed) catch |err| {
            std.debug.print(
                "\nfuzz FAILURE (reader-stream-large): {t}\n  seed: 0x{x}\n  iteration: {d}\n  input ({d} bytes): ",
                .{ err, seed, iter, large.len },
            );
            printEscaped(large);
            std.debug.print("\n", .{});
            std.process.exit(1);
        };
    }

    std.debug.print("fuzz: {d} iterations OK (seed 0x{x})\n", .{ iterations, seed });
}

/// Build one input in `input_buf`: either fully random bytes or a seed
/// document put through 1..8 random mutations.
fn generateInput(random: Random) []const u8 {
    if (random.uintLessThan(u8, 8) == 0) {
        // Fully random bytes; mostly short, occasionally multi-KB.
        const len = if (random.boolean())
            random.uintAtMost(usize, 64)
        else
            random.uintAtMost(usize, 4096);
        random.bytes(input_buf[0..len]);
        return input_buf[0..len];
    }

    const doc = seed_docs[random.uintLessThan(usize, seed_docs.len)];
    @memcpy(input_buf[0..doc.len], doc);
    var len = doc.len;

    const mutations = 1 + random.uintLessThan(usize, 8);
    var m: usize = 0;
    while (m < mutations) : (m += 1) {
        len = mutate(random, len);
        if (len == 0) break;
    }
    return input_buf[0..len];
}

/// Apply one random mutation to `input_buf[0..len]`; returns the new length.
fn mutate(random: Random, len: usize) usize {
    switch (random.uintLessThan(u8, 5)) {
        // flip one byte
        0 => {
            if (len == 0) return len;
            const pos = random.uintLessThan(usize, len);
            input_buf[pos] ^= @as(u8, 1) << random.int(u3);
            return len;
        },
        // insert a random byte
        1 => {
            if (len >= max_input_bytes) return len;
            const pos = random.uintAtMost(usize, len);
            std.mem.copyBackwards(u8, input_buf[pos + 1 .. len + 1], input_buf[pos..len]);
            input_buf[pos] = random.int(u8);
            return len + 1;
        },
        // delete one byte
        2 => {
            if (len == 0) return len;
            const pos = random.uintLessThan(usize, len);
            std.mem.copyForwards(u8, input_buf[pos .. len - 1], input_buf[pos + 1 .. len]);
            return len - 1;
        },
        // truncate
        3 => return random.uintAtMost(usize, len),
        // splice a random slice of a seed document into a random position
        4 => {
            const doc = seed_docs[random.uintLessThan(usize, seed_docs.len)];
            const start = random.uintAtMost(usize, doc.len);
            var n = random.uintAtMost(usize, doc.len - start);
            if (len + n > max_input_bytes) n = max_input_bytes - len;
            const pos = random.uintAtMost(usize, len);
            @memcpy(splice_buf[0 .. len - pos], input_buf[pos..len]);
            @memcpy(input_buf[pos .. pos + n], doc[start .. start + n]);
            @memcpy(input_buf[pos + n .. len + n], splice_buf[0 .. len - pos]);
            return len + n;
        },
        else => unreachable,
    }
}

/// Build a valid JSON array that is guaranteed to exceed the 4096-byte pull
/// chunk size so `EventReader.fromReader` must call `pull()` more than once.
/// Output is always well-formed JSON (ASCII strings), sized 8-16 KiB.
fn generateLargeJson(random: Random) []const u8 {
    var pos: usize = 0;
    large_json_buf[pos] = '[';
    pos += 1;

    const target: usize = 8 * 1024 + random.uintLessThan(usize, 8 * 1024);
    var need_comma = false;

    while (pos < target) {
        // Reserve room for comma, quotes, string body, and the closing bracket.
        if (pos + 600 >= large_json_buf.len) break;
        if (need_comma) {
            large_json_buf[pos] = ',';
            pos += 1;
        }
        need_comma = true;

        // Each element is a long ASCII string (256-767 letters).
        const str_len = 256 + random.uintLessThan(usize, 512);
        const room = large_json_buf.len - pos - 3;
        const n = @min(str_len, room);
        if (n == 0) break;
        large_json_buf[pos] = '"';
        pos += 1;
        var j: usize = 0;
        while (j < n) : (j += 1) large_json_buf[pos + j] = 'a' + random.uintLessThan(u8, 26);
        pos += n;
        large_json_buf[pos] = '"';
        pos += 1;
    }

    large_json_buf[pos] = ']';
    pos += 1;
    return large_json_buf[0..pos];
}

const Failure = error{
    EncodeFailed,
    ReparseFailed,
    TypedDivergence,
    RoundTripMismatch,
    ParseDocumentDisagree,
    EmitNotLossless,
    StreamAcceptRejectMismatch,
    OutOfMemory,
};

fn checkInput(a: std.mem.Allocator, random: Random, input: []const u8) Failure!void {
    for ([_]json.Dialect{ .json, .jsonc }) |dialect| {
        var diags: std.ArrayList(json.Diagnostic) = .empty;
        const errors_sink: ?*std.ArrayList(json.Diagnostic) =
            if (random.boolean()) &diags else null;

        const parsed: ?json.Value = json.parse(a, input, .{
            .dialect = dialect,
            .errors = errors_sink,
        }) catch |err| switch (err) {
            error.JsonParseError, error.NestingTooDeep => null,
            error.OutOfMemory => return error.OutOfMemory,
        };

        if (parsed) |value| try checkRoundTrip(a, value);
        try checkDocument(a, input, dialect, parsed != null);
        try checkRawMode(a, input, dialect);
        try checkFeedSplit(a, random, input, dialect, parsed != null);
        try checkReaderStream(a, input, dialect, parsed);
        try checkTypedStream(a, input, dialect);
    }
}

/// Typed streaming invariant: `parseInto` streams token-to-field for
/// eligible types and falls back to parse+decode on any error, so the
/// dangerous divergence is one-directional: the streaming pass succeeding
/// where the tree path fails, or producing a different value. Decode a
/// battery of permissive target types both ways and require agreement.
fn checkTypedStream(a: std.mem.Allocator, input: []const u8, dialect: json.Dialect) Failure!void {
    const AllOpt = struct {
        a: ?f64 = null,
        b: ?[]const u8 = null,
        c: ?bool = null,
        tags: ?[]const []const u8 = null,
        nested: ?struct { x: ?i64 = null, y: ?[]const f64 = null } = null,
        mode: ?enum { alpha, beta } = null,
        renamed_field: ?f64 = null,
        pub const json_rename = .{ .renamed_field = "renamed" };
    };
    inline for (.{ AllOpt, []const AllOpt, []const f64, []const []const u8, [2]f64 }) |T| {
        const opts: json.ParseOptions = .{ .dialect = dialect, .ignore_unknown_fields = true };
        const streamed_opt: ?T = json.parseInto(T, a, input, opts) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break :blk null;
        };
        const tree_opt: ?T = treeParseInto(T, a, input, opts) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break :blk null;
        };
        if ((streamed_opt == null) != (tree_opt == null)) return error.TypedDivergence;
        if (streamed_opt) |sv| {
            if (!eqlT(T, sv, tree_opt.?)) return error.TypedDivergence;
        }
    }
}

/// The tree path `parseInto` streams past: parse to a Value, then decode.
fn treeParseInto(comptime T: type, a: std.mem.Allocator, input: []const u8, opts: json.ParseOptions) !T {
    const value = try json.parse(a, input, opts);
    return json.decode(T, a, value, opts);
}

/// Deep structural equality over a decoded target type.
fn eqlT(comptime T: type, x: T, y: T) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .@"enum" => x == y,
        .float => (std.math.isNan(x) and std.math.isNan(y)) or x == y,
        .optional => |o| blk: {
            if (x == null and y == null) break :blk true;
            if (x == null or y == null) break :blk false;
            break :blk eqlT(o.child, x.?, y.?);
        },
        .pointer => |p| blk: {
            if (p.child == u8 and p.is_const) break :blk std.mem.eql(u8, x, y);
            if (x.len != y.len) break :blk false;
            for (x, y) |xe, ye| {
                if (!eqlT(p.child, xe, ye)) break :blk false;
            }
            break :blk true;
        },
        .array => |arr| blk: {
            for (x, y) |xe, ye| {
                if (!eqlT(arr.child, xe, ye)) break :blk false;
            }
            break :blk true;
        },
        .@"struct" => |st| blk: {
            inline for (st.fields) |f| {
                if (!eqlT(f.type, @field(x, f.name), @field(y, f.name))) break :blk false;
            }
            break :blk true;
        },
        else => @compileError("eqlT: unsupported type " ++ @typeName(T)),
    };
}

/// Raw-number mode invariant: parsing succeeds exactly when typed mode
/// does, encode never fails (raw lexemes re-emit verbatim, so no
/// UnrepresentableFloat), and parse -> encode -> parse (raw) is deeply
/// equal. The raw lexemes are byte-preserved, so re-parse must match.
fn checkRawMode(a: std.mem.Allocator, input: []const u8, dialect: json.Dialect) Failure!void {
    const value = json.parse(a, input, .{ .dialect = dialect, .number_mode = .raw }) catch |err| switch (err) {
        error.JsonParseError, error.NestingTooDeep => return,
        error.OutOfMemory => return error.OutOfMemory,
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    json.encode(&aw.writer, value) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        // Raw mode emits verbatim lexemes; floats never reach the encoder.
        error.UnrepresentableFloat, error.NestingTooDeep => return error.EncodeFailed,
    };
    const reparsed = json.parse(a, aw.written(), .{ .number_mode = .raw }) catch return error.ReparseFailed;
    if (!valueEql(value, reparsed)) return error.RoundTripMismatch;
}

/// Invariant 2: encode the parsed tree and re-parse; trees must be
/// deeply equal. `UnrepresentableFloat` is the one legal encode failure
/// (the tree can hold +/-inf parsed from huge exponents).
fn checkRoundTrip(a: std.mem.Allocator, value: json.Value) Failure!void {
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    json.encode(&aw.writer, value) catch |err| switch (err) {
        error.UnrepresentableFloat => return,
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.NestingTooDeep => return error.EncodeFailed,
    };
    const reparsed = json.parse(a, aw.written(), .{}) catch return error.ReparseFailed;
    if (!valueEql(value, reparsed)) return error.RoundTripMismatch;
}

/// Invariant 3: `Document.parse` agrees with `parse` on accept/reject,
/// and an accepted document emits its input byte-for-byte.
fn checkDocument(a: std.mem.Allocator, input: []const u8, dialect: json.Dialect, parse_ok: bool) Failure!void {
    const doc = json.Document.parse(a, input, .{ .dialect = dialect }) catch |err| switch (err) {
        error.JsonParseError, error.NestingTooDeep, error.InvalidComment => {
            if (parse_ok) return error.ParseDocumentDisagree;
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
        // Edit-path errors; parse cannot return them.
        error.PathNotFound, error.InvalidValue, error.CommentsNotSupported => unreachable,
    };
    if (!parse_ok) return error.ParseDocumentDisagree;

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    doc.emit(&aw.writer) catch return error.OutOfMemory;
    if (!std.mem.eql(u8, input, aw.written())) return error.EmitNotLossless;
}

/// Feed-split invariant: feed the input in random chunks through an EventReader
/// and assert the accept/reject decision matches `parse` on the same bytes.
/// Streaming "accepts" when it can materialize a single top-level value and then
/// sees end_of_input; "rejects" when it returns any error other than NeedMoreInput.
/// The check is dialect-aware: `dialect` is forwarded so the split path is
/// exercised for both strict JSON and JSONC.
fn checkFeedSplit(a: std.mem.Allocator, random: Random, input: []const u8, dialect: json.Dialect, parse_ok: bool) Failure!void {
    // Pick 1-8 random split points within [0, input.len].
    const num_splits = 1 + random.uintLessThan(usize, 8);
    var splits: [10]usize = undefined; // up to 8 splits + start + end = 10 entries
    splits[0] = 0;
    var s: usize = 0;
    while (s < num_splits) : (s += 1) {
        splits[s + 1] = random.uintAtMost(usize, input.len);
    }
    splits[num_splits + 1] = input.len;
    // Sort split boundaries so chunks are non-overlapping and in order.
    std.mem.sort(usize, splits[0 .. num_splits + 2], {}, std.sort.asc(usize));
    const num_chunks = num_splits + 1;

    // Use the iteration arena for the EventReader's internal buffers. The arena
    // resets at the end of each outer iteration, so no explicit deinit is needed.
    // We still call deinit defensively; for arena-backed allocators it is a no-op.
    var er = json.EventReader.init(a, .{ .dialect = dialect });
    defer er.deinit();

    // Feed all chunks, then end input. `feed` only fails on OutOfMemory.
    var chunk: usize = 0;
    while (chunk < num_chunks) : (chunk += 1) {
        const lo = splits[chunk];
        const hi = splits[chunk + 1];
        er.feed(input[lo..hi]) catch return error.OutOfMemory;
    }
    er.endInput();

    // Determine accept/reject by materializing a single top-level value and
    // then checking that end_of_input follows. Allocate into `a` directly;
    // the outer iteration arena resets after checkInput returns.
    const stream_ok: bool = blk: {
        // Position the reader at the first event. After endInput, NeedMoreInput
        // cannot recur; any other error is a parse rejection.
        const ev0 = er.next() catch |e| switch (e) {
            error.NeedMoreInput => break :blk false,
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk false,
        };
        const first = ev0 orelse break :blk false;

        // end_of_input on an empty stream: no value was parsed, so reject.
        if (std.meta.activeTag(first.kind) == .end_of_input) break :blk false;

        // Materialize the top-level value into the iteration arena.
        _ = er.materialize(a) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk false,
        };

        // The next event must be end_of_input; trailing garbage means reject.
        const ev1 = er.next() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk false,
        };
        const next = ev1 orelse break :blk false;
        break :blk std.meta.activeTag(next.kind) == .end_of_input;
    };

    if (stream_ok != parse_ok) return error.StreamAcceptRejectMismatch;
}

/// Assert that `EventReader.fromReader` over an in-memory reader produces the
/// same result as `json.parse`.  `buffered` is the tree already produced by
/// `json.parse` (null when parse rejected the input).  The reader-backed path
/// fires `pull()` internally whenever `NeedMoreInput` would occur, exercising
/// the real refill code path that the `feed()`+`endInput()` arm never reaches.
fn checkReaderStream(
    a: std.mem.Allocator,
    input: []const u8,
    dialect: json.Dialect,
    buffered: ?json.Value,
) Failure!void {
    var r: std.Io.Reader = .fixed(input);
    var er = json.EventReader.fromReader(a, &r, .{ .dialect = dialect });
    defer er.deinit();

    const streamed: ?json.Value = blk: {
        const ev0 = er.next() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk null,
        };
        const first = ev0 orelse break :blk null;
        // Empty stream: no value produced; treat as rejection to match json.parse.
        if (std.meta.activeTag(first.kind) == .end_of_input) break :blk null;

        const mat = er.materialize(a) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk null,
        };

        // Trailing content after the value counts as rejection.
        const ev1 = er.next() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk null,
        };
        const trailing = ev1 orelse break :blk null;
        if (std.meta.activeTag(trailing.kind) != .end_of_input) break :blk null;

        break :blk mat;
    };

    // Success/failure parity between streamed and buffered paths.
    if ((streamed != null) != (buffered != null)) return error.StreamAcceptRejectMismatch;
    // Deep equality when both succeed.
    if (buffered) |buf| if (streamed) |str| {
        if (!valueEql(buf, str)) return error.RoundTripMismatch;
    };
}

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

/// Print `input` as a double-quoted string with non-printable bytes as
/// \xNN escapes, so a failing case can be pasted into a regression test.
fn printEscaped(input: []const u8) void {
    std.debug.print("\"", .{});
    for (input) |byte| {
        switch (byte) {
            '"' => std.debug.print("\\\"", .{}),
            '\\' => std.debug.print("\\\\", .{}),
            ' '...'!', '#'...'[', ']'...'~' => std.debug.print("{c}", .{byte}),
            else => std.debug.print("\\x{x:0>2}", .{byte}),
        }
    }
    std.debug.print("\"", .{});
}
