//! JSON value types.
//!
//! `Value` is a tagged union covering every JSON value kind: null, bool,
//! number (integer or float), string, array, object.
//!
//! Memory model: all allocations belong to a caller-owned arena. Free
//! everything with `arena.deinit()`. `string` may be a zero-copy slice
//! into the original input buffer or an arena-allocated copy; the caller
//! must keep the input alive while the parse tree is in use.

const std = @import("std");
const testing = std.testing;

/// Hard stack-safe ceiling on recursion depth for the recursive code paths:
/// the recursive-descent tree parser, the `Document` node builder, and the
/// `Value` encoder. Each consumes one host stack frame per nesting level, so
/// an unbounded depth would overflow the stack (SIGSEGV) on untrusted input.
///
/// The effective recursive limit is `min(ParseOptions.max_depth, this)`: a
/// caller raising `max_depth` past this ceiling gets `error.NestingTooDeep`,
/// never a crash. For deeper input use the iterative streaming
/// `EventReader` / `materialize`: their stack is heap-allocated, so they
/// have no hard ceiling and `StreamOptions.max_depth` can be raised past 128.
///
/// 128 is the depth the recursive parser is measured safe at on the smallest
/// supported thread stack -- a 512 KiB worker stack (the platform default for
/// spawned threads on macOS), even in a Debug build where frames are largest
/// (~3 KiB/level, overflow near ~150). On the default 8 MiB main/test stack
/// the margin is ~100x. Deeper recursion cannot be made stack-safe on a
/// 512 KiB stack, so the recursive paths stop here and defer to streaming.
pub const recursive_depth_ceiling: usize = 128;

/// 1-indexed line/column derived from a byte offset. Produced by `Span.lineCol`.
pub const LineCol = struct {
    line: u32,
    col: u32,
};

/// Source byte range of a parsed value, as offsets into the input buffer.
/// Offsets are u64, so a span addresses any in-memory `[]const u8` without a
/// 4 GiB cap. Line/column are not stored; derive them on demand with `lineCol`.
pub const Span = struct {
    start: u64,
    end: u64,

    /// 1-indexed line and column of `start` within `src`. O(start): scans
    /// `src[0..start]` counting newlines. Intended for occasional human-facing
    /// location display (diagnostics, tooling), not bulk per-value use. Column
    /// is the byte count since the last newline, plus one. Both saturate at
    /// `maxInt(u32)` for absurdly large inputs.
    pub fn lineCol(self: Span, src: []const u8) LineCol {
        const limit = @min(self.start, src.len);
        var line: u64 = 1;
        var line_start: u64 = 0;
        var i: u64 = 0;
        while (i < limit) : (i += 1) {
            if (src[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        return .{
            .line = std.math.cast(u32, line) orelse std.math.maxInt(u32),
            .col = std.math.cast(u32, limit - line_start + 1) orelse std.math.maxInt(u32),
        };
    }
};

/// A map from dotted path to source span (e.g., "users[0].name" ->
/// Span). Array elements use `[N]` index segments; the root value's
/// path is the empty string `""`. Populated by the parser via
/// `ParseOptions.spans`; see `Value.locate` for the paired lookup helper.
///
/// Keys are stored as-is: a key whose bytes contain `.` or `[` may
/// collide with a structurally different nested path (e.g. the key
/// `"a.b"` and key `"b"` inside object `"a"` both map to path "a.b"),
/// in which case the later recording wins.
///
/// Span path keys recorded by the parser are arena-allocated and live
/// as long as the value tree. The map stores key slices, not copies, so
/// callers populating it themselves must not key it with reused scratch
/// buffers.
pub const Spans = std.StringHashMapUnmanaged(Span);

/// Insertion-order-preserving string-keyed map used for objects, so
/// re-emitting a document keeps member order deterministic.
pub const ObjectMap = std.StringArrayHashMapUnmanaged(Value);

/// Iterator over the segments of a dotted path: `a.b[2].c` yields keys
/// "a", "b", index 2, key "c". The single owner of the path grammar;
/// `Value.get`, `Document.resolve`, and the document's parent/leaf
/// splitting all walk paths through it.
///
/// Grammar:
/// - Key segments end at `.` or `[`; one `.` after a segment is
///   consumed as the separator, so a trailing dot yields nothing
///   (`"a."` iterates like `"a"`) and consecutive dots yield an empty
///   key (which only matches a literal `""` key).
/// - `[N]` yields an index when N parses as usize. A bracket whose
///   interior is empty, non-numeric, negative, or overflows usize
///   yields `.raw` instead, as does an unclosed `[`; lookups treat
///   `.raw` as matching nothing.
pub const PathIterator = struct {
    path: []const u8,
    pos: usize = 0,
    /// Offset just past the last consumed separator (a skipped `.` or
    /// a bracket's `]`): where the path's final raw tail starts once
    /// iteration ends. The document's parent/leaf splitting slices the
    /// original path bytes here.
    tail_start: usize = 0,

    pub const Segment = union(enum) {
        key: []const u8,
        index: usize,
        /// Malformed bracket segment: unclosed `[`, or `[...]` whose
        /// interior is not a valid usize. Matches nothing.
        raw,
    };

    pub fn init(path: []const u8) PathIterator {
        return .{ .path = path };
    }

    pub fn next(self: *PathIterator) ?Segment {
        if (self.pos >= self.path.len) return null;
        if (self.path[self.pos] == '[') {
            if (std.mem.indexOfScalarPos(u8, self.path, self.pos + 1, ']')) |close| {
                const interior = self.path[self.pos + 1 .. close];
                self.pos = close + 1;
                self.tail_start = self.pos;
                self.skipDot();
                const idx = std.fmt.parseInt(usize, interior, 10) catch return .raw;
                return .{ .index = idx };
            }
            // Unclosed bracket: the bytes up to the next `.` (or the
            // end) form one raw segment; later `.`-separated segments
            // still iterate so `tail_start` stays exact.
            self.pos = std.mem.indexOfScalarPos(u8, self.path, self.pos + 1, '.') orelse self.path.len;
            self.skipDot();
            return .raw;
        }
        const start = self.pos;
        while (self.pos < self.path.len and self.path[self.pos] != '.' and self.path[self.pos] != '[') {
            self.pos += 1;
        }
        const segment = self.path[start..self.pos];
        self.skipDot();
        return .{ .key = segment };
    }

    fn skipDot(self: *PathIterator) void {
        if (self.pos < self.path.len and self.path[self.pos] == '.') {
            self.pos += 1;
            self.tail_start = self.pos;
        }
    }
};

/// Dynamic JSON value. Objects preserve insertion order for deterministic emit.
pub const Value = union(enum) {
    null,
    bool: bool,
    /// Integer-syntax JSON numbers in the range [minInt(i128), maxInt(i128)].
    /// Values outside this range are stored as `.float` (typed mode) or
    /// `.number_raw` (raw mode). Use `getT(u64, ...)` etc. to narrow.
    integer: i128,
    float: f64,
    string: []const u8,
    array: []Value,
    object: ObjectMap,
    /// Verbatim source lexeme of a number, preserved exactly (no i128/f64
    /// rounding, `1e2` distinct from `100.0`, trailing zeros kept). Only
    /// produced when parsing with `ParseOptions.number_mode = .raw`; the
    /// default `.typed` mode never yields this variant. The slice is
    /// zero-copy into the input, so the input must outlive the tree.
    /// `getT` coerces it to int/float on demand; the encoder emits it
    /// byte-for-byte.
    number_raw: []const u8,

    /// Look up a dotted path. Returns null if any segment is missing or
    /// traverses through a non-object. Array indices use `[N]` syntax:
    /// `users[0].name`, `matrix[3][7]`. A trailing `.` (e.g., `"a."`) is
    /// stripped -- `get("a.")` and `get("a")` return the same value.
    /// Segments split on `.` and `[` (see `PathIterator`), so a key
    /// whose bytes contain either character cannot be addressed through
    /// a path.
    pub fn get(self: Value, path: []const u8) ?Value {
        var cur = self;
        var it = PathIterator.init(path);
        while (it.next()) |segment| {
            switch (segment) {
                .key => |k| {
                    if (cur != .object) return null;
                    cur = cur.object.get(k) orelse return null;
                },
                .index => |idx| {
                    if (cur != .array) return null;
                    if (idx >= cur.array.len) return null;
                    cur = cur.array[idx];
                },
                .raw => return null,
            }
        }
        return cur;
    }

    /// Paired result of `locate`: the value at `path` plus its source span.
    pub const Located = struct {
        value: Value,
        span: Span,
    };

    /// Look up a value at `path` AND its source span in one call. Returns
    /// null if the path is missing OR if the span map doesn't carry an
    /// entry for this path. Avoids typing the path twice when you need
    /// both pieces. Spans are populated when `parse` was called with
    /// `ParseOptions.spans` set.
    pub fn locate(self: Value, spans: Spans, path: []const u8) ?Located {
        const v = self.get(path) orelse return null;
        const span = spans.get(path) orelse return null;
        return .{ .value = v, .span = span };
    }

    /// Look up + decode to T in one step. Returns null on missing OR on
    /// type mismatch. Supported T: bool, integer types (overflow returns
    /// null), float types (a `.integer` value coerces), `[]const u8`,
    /// `Value` (passthrough).
    pub fn getT(self: Value, comptime T: type, path: []const u8) ?T {
        const v = self.get(path) orelse return null;
        if (T == Value) return v;
        return switch (@typeInfo(T)) {
            .bool => if (v == .bool) v.bool else null,
            .int => switch (v) {
                .integer => |n| std.math.cast(T, n),
                // Parse the raw lexeme directly into T: skips the i128
                // intermediary for targets wider than i128 (u128) or
                // narrower. Non-integer syntax (float lexeme) fails here
                // and returns null, matching the typed-mode policy.
                .number_raw => |raw| std.fmt.parseInt(T, raw, 10) catch null,
                else => null,
            },
            .float => switch (v) {
                .float => |f| blk: {
                    const result: T = @floatCast(f);
                    // Finite source narrowing to inf is overflow; genuine inf/nan passes through.
                    break :blk if (!std.math.isInf(f) and std.math.isInf(result)) null else @as(?T, result);
                },
                .integer => |n| blk: {
                    const result: T = @floatFromInt(n);
                    break :blk if (std.math.isInf(result)) null else @as(?T, result);
                },
                .number_raw => |raw| if (std.fmt.parseFloat(f64, raw)) |f| blk: {
                    const result: T = @floatCast(f);
                    break :blk if (!std.math.isInf(f) and std.math.isInf(result)) null else @as(?T, result);
                } else |_| null,
                else => null,
            },
            .pointer => |p| if (p.size == .slice and p.child == u8 and p.is_const)
                (if (v == .string) v.string else null)
            else
                @compileError("Value.getT: only []const u8 slices supported, got " ++ @typeName(T)),
            else => @compileError("Value.getT: unsupported type " ++ @typeName(T)),
        };
    }
};

test "value getT walks dotted paths and array indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var users: ObjectMap = .empty;
    try users.put(a, "name", .{ .string = "ada" });
    const elems = try a.dupe(Value, &.{.{ .object = users }});
    var root_map: ObjectMap = .empty;
    try root_map.put(a, "users", .{ .array = elems });
    const root: Value = .{ .object = root_map };

    try std.testing.expectEqualStrings("ada", root.getT([]const u8, "users[0].name").?);
    try std.testing.expectEqual(@as(?u16, null), root.getT(u16, "users[0].name"));
    try std.testing.expectEqual(@as(?u16, null), root.getT(u16, "missing"));
}

test "Value.get: dotted path traversal three objects deep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var inner: ObjectMap = .empty;
    try inner.put(a, "port", .{ .integer = 8080 });
    var server: ObjectMap = .empty;
    try server.put(a, "listen", .{ .object = inner });
    var root_map: ObjectMap = .empty;
    try root_map.put(a, "server", .{ .object = server });
    const root: Value = .{ .object = root_map };

    try testing.expectEqual(@as(i128, 8080), root.get("server.listen.port").?.integer);
    try testing.expect(root.get("server.listen.missing") == null);
    try testing.expect(root.get("server.missing.port") == null);
    try testing.expect(root.get("server.listen.port.deeper") == null); // can't traverse through scalar
    try testing.expectEqual(@as(i128, 8080), root.get("server.listen.port.").?.integer); // trailing dot stripped
}

test "Value.get: adjacent array indices (matrix[i][j] style)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const row0 = try a.dupe(Value, &.{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } });
    const row1 = try a.dupe(Value, &.{ .{ .integer = 4 }, .{ .integer = 5 }, .{ .integer = 6 } });
    const rows = try a.dupe(Value, &.{ .{ .array = row0 }, .{ .array = row1 } });
    var root_map: ObjectMap = .empty;
    try root_map.put(a, "rows", .{ .array = rows });
    const root: Value = .{ .object = root_map };

    try testing.expectEqual(@as(i128, 1), root.get("rows[0][0]").?.integer);
    try testing.expectEqual(@as(i128, 6), root.get("rows[1][2]").?.integer);
    try testing.expect(root.get("rows[2][0]") == null); // out of bounds
    try testing.expect(root.get("rows[0][3]") == null); // out of bounds
    try testing.expect(root.get("rows[0]nope") == null); // index into non-array via key
}

test "Value.get: key containing a dot is unaddressable through a path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root_map: ObjectMap = .empty;
    try root_map.put(a, "a.b", .{ .integer = 1 });
    const root: Value = .{ .object = root_map };

    // The path splits into segments "a" then "b"; neither exists, so the
    // literal key "a.b" is reachable only via the ObjectMap directly.
    try testing.expect(root.get("a.b") == null);
    try testing.expectEqual(@as(i128, 1), root.object.get("a.b").?.integer);
}

test "Value.get: malformed paths return null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const elems = try a.dupe(Value, &.{ .{ .integer = 10 }, .{ .integer = 20 } });
    var inner: ObjectMap = .empty;
    try inner.put(a, "k", .{ .integer = 1 });
    var root_map: ObjectMap = .empty;
    try root_map.put(a, "a", .{ .array = elems });
    try root_map.put(a, "obj", .{ .object = inner });
    const root: Value = .{ .object = root_map };

    try testing.expect(root.get("a[") == null); // unclosed bracket
    try testing.expect(root.get("a[]") == null); // empty index
    try testing.expect(root.get("a[x]") == null); // non-numeric index
    try testing.expect(root.get("a[-1]") == null); // negative index
    try testing.expect(root.get("a[99999999999999999999]") == null); // usize overflow
    try testing.expect(root.get("a..b") == null); // empty segment
    try testing.expect(root.get(".a") == null); // leading dot
    try testing.expect(root.get("obj[0]") == null); // index into an object
}

test "Value.get: empty path returns self" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root_map: ObjectMap = .empty;
    try root_map.put(a, "x", .{ .integer = 1 });
    const root: Value = .{ .object = root_map };

    const whole = root.get("").?;
    try testing.expect(whole == .object);
    try testing.expectEqual(@as(usize, 1), whole.object.count());

    const scalar: Value = .{ .integer = 7 };
    try testing.expectEqual(@as(i128, 7), scalar.get("").?.integer);
}

test "Value.getT: typed access incl. range check and coercions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root_map: ObjectMap = .empty;
    try root_map.put(a, "port", .{ .integer = 300 });
    try root_map.put(a, "pi", .{ .float = 3.5 });
    try root_map.put(a, "tls", .{ .bool = true });
    try root_map.put(a, "name", .{ .string = "x" });
    try root_map.put(a, "nothing", .null);
    const root: Value = .{ .object = root_map };

    try testing.expectEqual(@as(?u16, 300), root.getT(u16, "port"));
    try testing.expectEqual(@as(?u8, null), root.getT(u8, "port")); // 300 overflows u8
    try testing.expectEqual(@as(?f64, 3.5), root.getT(f64, "pi"));
    try testing.expectEqual(@as(?f64, 300.0), root.getT(f64, "port")); // float from integer
    try testing.expectEqual(@as(?f32, 3.5), root.getT(f32, "pi"));
    try testing.expectEqual(@as(?bool, true), root.getT(bool, "tls"));
    try testing.expectEqualStrings("x", root.getT([]const u8, "name").?);

    // Wrong-type lookups return null, never error.
    try testing.expect(root.getT(u16, "name") == null);
    try testing.expect(root.getT(bool, "port") == null);
    try testing.expect(root.getT([]const u8, "tls") == null);
    try testing.expect(root.getT(f64, "name") == null);
    try testing.expect(root.getT(u16, "nothing") == null);

    // Value passthrough returns the union itself, any variant.
    const v = root.getT(Value, "nothing").?;
    try testing.expect(v == .null);
    try testing.expectEqual(@as(i128, 300), root.getT(Value, "port").?.integer);
}

test "Value.getT: float narrowing overflow returns null" {
    // 1e40 is finite as f64 but overflows f32 (~3.4e38 max).
    const v_big: Value = .{ .float = 1e40 };
    try testing.expect(v_big.getT(f32, "") == null);
    // In-range value must return the cast result.
    const v_small: Value = .{ .float = 3.0e38 };
    const as_f32 = v_small.getT(f32, "");
    try testing.expect(as_f32 != null and !std.math.isInf(as_f32.?));
    // f64 target -- no narrowing, finite 1e40 must return the value.
    try testing.expect(v_big.getT(f64, "") != null);
    // Genuine inf source must pass through (not treated as overflow).
    const v_inf: Value = .{ .float = std.math.inf(f64) };
    try testing.expect(v_inf.getT(f32, "") != null);
    try testing.expect(std.math.isInf(v_inf.getT(f32, "").?));
    // Integer 66000 overflows f16 (max 65504) via @floatFromInt.
    const v_int: Value = .{ .integer = 66000 };
    try testing.expect(v_int.getT(f16, "") == null);
    try testing.expect(v_int.getT(f64, "") != null);
}

test "Value.getT: number_raw coerces to typed int and float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root_map: ObjectMap = .empty;
    try root_map.put(a, "n", .{ .number_raw = "42" });
    try root_map.put(a, "x", .{ .number_raw = "1.5" });
    try root_map.put(a, "e", .{ .number_raw = "1e2" });
    const root: Value = .{ .object = root_map };

    try testing.expectEqual(@as(?i64, 42), root.getT(i64, "n"));
    try testing.expectEqual(@as(?u8, 42), root.getT(u8, "n"));
    try testing.expectEqual(@as(?f64, 1.5), root.getT(f64, "x"));
    try testing.expectEqual(@as(?f64, 100.0), root.getT(f64, "e"));
    // A float lexeme is not an integer; int access of "1.5"/"1e2" -> null.
    try testing.expect(root.getT(i64, "x") == null);
    try testing.expect(root.getT(i64, "e") == null);
    // A raw number is never a string.
    try testing.expect(root.getT([]const u8, "n") == null);
    // Value passthrough yields the number_raw variant itself.
    try testing.expectEqualStrings("42", root.getT(Value, "n").?.number_raw);
}

test "Value.locate: paired value + span lookup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var server: ObjectMap = .empty;
    try server.put(a, "port", .{ .integer = 8080 });
    var root_map: ObjectMap = .empty;
    try root_map.put(a, "server", .{ .object = server });
    const root: Value = .{ .object = root_map };

    var spans: Spans = .empty;
    try spans.put(a, "server.port", .{ .start = 20, .end = 24 });

    const located = root.locate(spans, "server.port").?;
    try testing.expectEqual(@as(i128, 8080), located.value.integer);
    try testing.expectEqual(@as(u64, 20), located.span.start);
    try testing.expectEqual(@as(u64, 24), located.span.end);

    try testing.expect(root.locate(spans, "missing") == null);

    // Value present but spans wasn't tracked for it.
    const empty_spans: Spans = .empty;
    try testing.expect(root.locate(empty_spans, "server.port") == null);
}

test "PathIterator: keys, indices, and adjacent brackets" {
    var it = PathIterator.init("a.b[2].c");
    try testing.expectEqualStrings("a", it.next().?.key);
    try testing.expectEqualStrings("b", it.next().?.key);
    try testing.expectEqual(@as(usize, 2), it.next().?.index);
    try testing.expectEqualStrings("c", it.next().?.key);
    try testing.expect(it.next() == null);

    var matrix = PathIterator.init("m[0][1]x");
    try testing.expectEqualStrings("m", matrix.next().?.key);
    try testing.expectEqual(@as(usize, 0), matrix.next().?.index);
    try testing.expectEqual(@as(usize, 1), matrix.next().?.index);
    try testing.expectEqualStrings("x", matrix.next().?.key);
    try testing.expect(matrix.next() == null);

    var empty = PathIterator.init("");
    try testing.expect(empty.next() == null);
}

test "PathIterator: trailing dot, empty segments, malformed brackets" {
    var trailing = PathIterator.init("a.");
    try testing.expectEqualStrings("a", trailing.next().?.key);
    try testing.expect(trailing.next() == null);

    var empties = PathIterator.init("a..b");
    try testing.expectEqualStrings("a", empties.next().?.key);
    try testing.expectEqualStrings("", empties.next().?.key);
    try testing.expectEqualStrings("b", empties.next().?.key);
    try testing.expect(empties.next() == null);

    var leading = PathIterator.init(".a");
    try testing.expectEqualStrings("", leading.next().?.key);
    try testing.expectEqualStrings("a", leading.next().?.key);
    try testing.expect(leading.next() == null);

    var unclosed = PathIterator.init("a[");
    try testing.expectEqualStrings("a", unclosed.next().?.key);
    try testing.expect(unclosed.next().? == .raw);
    try testing.expect(unclosed.next() == null);

    var bad_interior = PathIterator.init("a[x]b");
    try testing.expectEqualStrings("a", bad_interior.next().?.key);
    try testing.expect(bad_interior.next().? == .raw);
    try testing.expectEqualStrings("b", bad_interior.next().?.key);
    try testing.expect(bad_interior.next() == null);

    inline for (.{ "[]", "[-1]", "[99999999999999999999]" }) |p| {
        var it = PathIterator.init(p);
        try testing.expect(it.next().? == .raw);
        try testing.expect(it.next() == null);
    }
}

test "Span is 16 bytes (u64 offsets, no line/col)" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Span));
}

test "lineCol derives 1-indexed line/col from a byte offset" {
    const src = "ab\ncde\nf";
    // First byte.
    try testing.expectEqual(LineCol{ .line = 1, .col = 1 }, (Span{ .start = 0, .end = 0 }).lineCol(src));
    // Mid first line.
    try testing.expectEqual(LineCol{ .line = 1, .col = 2 }, (Span{ .start = 1, .end = 2 }).lineCol(src));
    // First byte after a newline.
    try testing.expectEqual(LineCol{ .line = 2, .col = 1 }, (Span{ .start = 3, .end = 4 }).lineCol(src));
    // Mid second line.
    try testing.expectEqual(LineCol{ .line = 2, .col = 3 }, (Span{ .start = 5, .end = 6 }).lineCol(src));
    // Start of third line.
    try testing.expectEqual(LineCol{ .line = 3, .col = 1 }, (Span{ .start = 7, .end = 8 }).lineCol(src));
    // Offset past end clamps to src length.
    try testing.expectEqual(LineCol{ .line = 3, .col = 2 }, (Span{ .start = 100, .end = 100 }).lineCol(src));
}
