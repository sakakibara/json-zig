//! Deterministic property/round-trip battery over `Document`'s lossless
//! editor.
//!
//! A fixed PRNG seed drives `case_count` bounded cases (nesting depth <= 4,
//! container fan-out <= 4). Each case builds a random valid JSONC document
//! plus a ground-truth model (path -> leaf value), picks an edit path and
//! value, and checks:
//!
//!   1. Set is total-or-clean: success, or a defined error with the source
//!      byte-unchanged.
//!   2. On success, the emitted output re-parses without error.
//!   3. The edited path reads back exactly the value that was set.
//!   4. Every other path in the model still reads back its original value.
//!   5. Every generated comment's text survives in the output; a pure
//!      value-replace is byte-identical except the value token.
//!   6. Re-applying the same edit is a byte-identical no-op.
//!   7. For a replace or append target, `removeSegments` then reparse
//!      leaves the path absent with siblings and comments intact.
//!
//! Paths are addressed through the segment API (`setValueSegments` /
//! `removeSegments`), which takes literal key segments only -- no `.`/`[N]`
//! re-splitting, and no way to target an array element. Generated keys
//! include an adversarial pool (literal dots, quotes, backslashes, leading
//! punctuation, number/bool/date-shaped names, control characters, empty
//! string) so the segment API's "any literal key" contract gets exercised,
//! not just bare identifiers. Occasionally the edit path walks through an
//! existing array-valued leaf; since the segment API cannot express an
//! index, this always hits the object-only intermediate-creation rule and
//! must fail cleanly (`error.InvalidValue`) -- the JSON analogue of "an
//! array index in a missing tail errors".
//!
//! On any failed assertion, the case index, seed, source, path, value, and
//! last-known output are printed before the test fails, so the case is
//! replayable by re-seeding `std.Random.DefaultPrng` with the printed seed.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = @import("json.zig");

const base_seed: u64 = 0x6a736f6e2d70726f; // "json-pro"
const case_count: usize = 3000;
const max_depth: usize = 4;
const max_fanout: usize = 4;

const Path = []const []const u8;

const Span = struct { start: usize, end: usize };

const ModelEntry = struct {
    path: Path,
    value: json.Value,
    /// Byte range of the value's token in the generated source. Only
    /// meaningful for the byte-exact-except-value check on a replace.
    span: Span,
};

/// Comment attribution for one direct child of some object (leaf or
/// nested container), in source order among its siblings. `remove`'s
/// documented contract deletes a member together with "the trivia between
/// it and its neighbor", and which side that trivia falls on depends on
/// the removed member's position (see `Document.removeSeg`'s object
/// branches): a non-last removal spans from the removed member's own key
/// to the next member's key, sweeping the removed member's own trailing
/// comment and the next member's leading comment, but never the removed
/// member's own leading comment (it sits before the deletion start); a
/// last removal (of more than one member) spans from the previous
/// member's value to the removed member's value, sweeping the previous
/// member's trailing comment and the removed member's own leading
/// comment, but never its own trailing comment (it sits after the
/// deletion end); removing the sole member wipes the whole interior,
/// taking both its own leading and trailing. The remove invariant
/// excludes exactly the trivia the applicable branch sweeps -- never the
/// union of all of them.
const MemberComment = struct {
    path: Path,
    leading: ?[]const u8,
    trailing: ?[]const u8,
};

const GenDoc = struct {
    source: []const u8,
    model: []const ModelEntry,
    /// Paths of every object node (including the root, `&.{}`), i.e. valid
    /// append/create targets. Arrays are never append targets.
    containers: []const Path,
    /// Delimited token of every generated comment (e.g. `/* note */` or
    /// `// note\n`), checked for presence by count (not exact position)
    /// after an edit.
    comments: []const []const u8,
    member_comments: []const MemberComment,
};

const CaseType = enum { replace, append, create, walk_leaf };

const Target = struct {
    path: Path,
    case_type: CaseType,
};

// Key / value / comment vocabularies

const bare_key_pool = [_][]const u8{
    "abc", "k1",  "foo_bar", "name",   "value", "item",  "data",
    "x",   "y",   "z",       "nested", "list",  "count", "flag",
    "id",  "tag", "meta",    "note",   "path",  "size",
};

const adversarial_key_pool = [_][]const u8{
    "a.b",
    "a\"b",
    "a\\b",
    "a b",
    "-abc",
    "?abc",
    "#abc",
    ";abc",
    "[abc",
    "true",
    "false",
    "null",
    "123",
    "1.5",
    "2024-01-01",
    "",
    "a\tb",
    "a\nb",
    "a\x01b",
    "\"quoted\"",
    "back\\slash\\end",
};

const plain_string_pool = [_][]const u8{
    "hello", "world", "example.com", "lorem", "ipsum", "value", "text", "sample",
};

const adversarial_string_pool = [_][]const u8{
    "true",            "false",            "null",                "123",
    "-3.14",           "- x",              "embedded \"quotes\"", "back\\slash",
    "line1\nline2",    "tab\there",        "\x01\x02control",     "",
    "  leading space", "trailing space  ", "[not, an, array]",    "{\"not\":\"object\"}",
};

const comment_word_pool = [_][]const u8{
    "note", "keep", "port", "host", "fixme", "review", "ok", "todo", "port8080", "tls",
};

fn genCommentText(rng: std.Random) []const u8 {
    return comment_word_pool[rng.uintLessThan(usize, comment_word_pool.len)];
}

fn containsStr(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// Picks a key not already in `used`, retrying against the adversarial and
/// bare-safe pools before falling back to a counter-suffixed key that is
/// guaranteed fresh.
fn genUniqueKey(a: Allocator, rng: std.Random, used: *std.ArrayList([]const u8)) ![]const u8 {
    var attempt: usize = 0;
    while (attempt < 25) : (attempt += 1) {
        const candidate = if (rng.boolean())
            bare_key_pool[rng.uintLessThan(usize, bare_key_pool.len)]
        else
            adversarial_key_pool[rng.uintLessThan(usize, adversarial_key_pool.len)];
        if (!containsStr(used.items, candidate)) return candidate;
    }
    return std.fmt.allocPrint(a, "fallback_key_{d}", .{used.items.len});
}

fn genInt(rng: std.Random) i128 {
    return rng.intRangeAtMost(i128, -1_000_000, 1_000_000);
}

fn genFloat(rng: std.Random) f64 {
    const n = rng.intRangeAtMost(i32, -100_000, 100_000);
    return @as(f64, @floatFromInt(n)) / 100.0;
}

fn genScalarValue(rng: std.Random) json.Value {
    return switch (rng.intRangeLessThan(u8, 0, 6)) {
        0 => .{ .bool = rng.boolean() },
        1 => .{ .integer = genInt(rng) },
        2 => .{ .float = genFloat(rng) },
        3 => .{ .string = plain_string_pool[rng.uintLessThan(usize, plain_string_pool.len)] },
        4 => .{ .string = adversarial_string_pool[rng.uintLessThan(usize, adversarial_string_pool.len)] },
        else => .null,
    };
}

fn genScalarArray(a: Allocator, rng: std.Random) ![]json.Value {
    const n = rng.intRangeAtMost(u8, 1, 3);
    const items = try a.alloc(json.Value, n);
    for (items) |*it| it.* = genScalarValue(rng);
    return items;
}

fn genSmallObjectValue(a: Allocator, rng: std.Random) !json.Value {
    var om: json.ObjectMap = .empty;
    var used: std.ArrayList([]const u8) = .empty;
    const n = rng.intRangeAtMost(u8, 1, 2);
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const key = try genUniqueKey(a, rng, &used);
        try used.append(a, key);
        try om.put(a, key, genScalarValue(rng));
    }
    return .{ .object = om };
}

/// The value handed to an edit: mostly a scalar, occasionally a small
/// nested object or array, and rarely a deliberately unrepresentable float
/// (NaN/+-inf) to exercise the clean-error path (invariant 1) alongside
/// the structurally-invalid paths `walk_leaf` already covers.
fn genEditValue(a: Allocator, rng: std.Random) !json.Value {
    const roll = rng.intRangeLessThan(u8, 0, 100);
    if (roll < 3) {
        const f: f64 = switch (rng.intRangeLessThan(u8, 0, 3)) {
            0 => std.math.nan(f64),
            1 => std.math.inf(f64),
            else => -std.math.inf(f64),
        };
        return .{ .float = f };
    }
    if (roll < 11) return genSmallObjectValue(a, rng);
    if (roll < 19) return .{ .array = try genScalarArray(a, rng) };
    return genScalarValue(rng);
}

fn appendSeg(a: Allocator, path: Path, seg: []const u8) !Path {
    const out = try a.alloc([]const u8, path.len + 1);
    @memcpy(out[0..path.len], path);
    out[path.len] = seg;
    return out;
}

fn pathEq(x: Path, y: Path) bool {
    if (x.len != y.len) return false;
    for (x, y) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

// Document generation

fn writeLeafValue(aw: *Io.Writer.Allocating, val: json.Value) !Span {
    const start = aw.written().len;
    try json.encode(&aw.writer, val, .{});
    const end = aw.written().len;
    return .{ .start = start, .end = end };
}

/// Returns the delimited comment token emitted (if any), so the caller can
/// attribute it to the member it precedes. The token includes the comment
/// delimiters (`/* ... */`, or `// ...` through the trailing newline) --
/// not just the bare word -- so a survival check that searches for the
/// token can never be fooled by another comment's word that happens to be
/// a prefix of this one, or by a colliding bare key.
fn maybeComment(a: Allocator, rng: std.Random, aw: *Io.Writer.Allocating, comments: *std.ArrayList([]const u8)) !?[]const u8 {
    switch (rng.intRangeLessThan(u8, 0, 10)) {
        0 => {
            const text = genCommentText(rng);
            try aw.writer.print("/* {s} */", .{text});
            const token = try std.fmt.allocPrint(a, "/* {s} */", .{text});
            try comments.append(a, token);
            return token;
        },
        1 => {
            const text = genCommentText(rng);
            try aw.writer.print("\n// {s}\n", .{text});
            const token = try std.fmt.allocPrint(a, "// {s}\n", .{text});
            try comments.append(a, token);
            return token;
        },
        2 => {
            try aw.writer.writeByte('\n');
            return null;
        },
        else => return null,
    }
}

/// Returns the delimited comment token emitted (if any), so the caller can
/// attribute it to the member it follows. See `maybeComment` for why the
/// token carries its delimiters.
fn maybeTrailingComment(a: Allocator, rng: std.Random, aw: *Io.Writer.Allocating, comments: *std.ArrayList([]const u8)) !?[]const u8 {
    if (rng.intRangeLessThan(u8, 0, 10) != 0) return null;
    const text = genCommentText(rng);
    try aw.writer.print(" // {s}\n", .{text});
    const token = try std.fmt.allocPrint(a, "// {s}\n", .{text});
    try comments.append(a, token);
    return token;
}

fn genObject(
    a: Allocator,
    rng: std.Random,
    aw: *Io.Writer.Allocating,
    model: *std.ArrayList(ModelEntry),
    containers: *std.ArrayList(Path),
    comments: *std.ArrayList([]const u8),
    member_comments: *std.ArrayList(MemberComment),
    path: Path,
    depth: usize,
) !void {
    try containers.append(a, path);
    try aw.writer.writeByte('{');
    const n = rng.intRangeAtMost(u8, 1, max_fanout);
    var used: std.ArrayList([]const u8) = .empty;
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try aw.writer.writeByte(',');
        const leading = try maybeComment(a, rng, aw, comments);
        const key = try genUniqueKey(a, rng, &used);
        try used.append(a, key);
        try json.encode(&aw.writer, .{ .string = key }, .{});
        try aw.writer.writeByte(':');
        const child_path = try appendSeg(a, path, key);

        const can_nest = depth + 1 < max_depth;
        const roll = rng.intRangeLessThan(u8, 0, 10);
        const trailing = blk: {
            if (can_nest and roll < 4) {
                try genObject(a, rng, aw, model, containers, comments, member_comments, child_path, depth + 1);
                break :blk try maybeTrailingComment(a, rng, aw, comments);
            } else if (roll < 6) {
                const val: json.Value = .{ .array = try genScalarArray(a, rng) };
                const span = try writeLeafValue(aw, val);
                const t = try maybeTrailingComment(a, rng, aw, comments);
                try model.append(a, .{ .path = child_path, .value = val, .span = span });
                break :blk t;
            } else {
                const val = genScalarValue(rng);
                const span = try writeLeafValue(aw, val);
                const t = try maybeTrailingComment(a, rng, aw, comments);
                try model.append(a, .{ .path = child_path, .value = val, .span = span });
                break :blk t;
            }
        };
        try member_comments.append(a, .{ .path = child_path, .leading = leading, .trailing = trailing });
    }
    try aw.writer.writeByte('}');
}

fn genDoc(a: Allocator, rng: std.Random) !GenDoc {
    var aw: Io.Writer.Allocating = .init(a);
    var model: std.ArrayList(ModelEntry) = .empty;
    var containers: std.ArrayList(Path) = .empty;
    var comments: std.ArrayList([]const u8) = .empty;
    var member_comments: std.ArrayList(MemberComment) = .empty;
    try genObject(a, rng, &aw, &model, &containers, &comments, &member_comments, &[_][]const u8{}, 0);
    return .{
        .source = aw.written(),
        .model = try model.toOwnedSlice(a),
        .containers = try containers.toOwnedSlice(a),
        .comments = try comments.toOwnedSlice(a),
        .member_comments = try member_comments.toOwnedSlice(a),
    };
}

// Edit-path selection

fn findModelEntry(model: []const ModelEntry, path: Path) ?ModelEntry {
    for (model) |m| {
        if (pathEq(m.path, path)) return m;
    }
    return null;
}

/// Keys already used directly under `container`, gathered from both
/// recorded leaves and nested containers, so a freshly generated sibling
/// key is genuinely new.
fn collectSiblingKeys(a: Allocator, gen: GenDoc, container: Path) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (gen.model) |m| {
        if (m.path.len == container.len + 1 and pathEq(m.path[0..container.len], container)) {
            try out.append(a, m.path[m.path.len - 1]);
        }
    }
    for (gen.containers) |c| {
        if (c.len == container.len + 1 and pathEq(c[0 .. c.len - 1], container)) {
            try out.append(a, c[c.len - 1]);
        }
    }
    return out.toOwnedSlice(a);
}

/// Direct children of `parent`, in source order, with their comment
/// attribution. Order is preserved because siblings are appended in
/// left-to-right generation order and each child's own subtree finishes
/// appending before its next sibling starts.
fn directChildComments(a: Allocator, gen: GenDoc, parent: Path) ![]const MemberComment {
    var out: std.ArrayList(MemberComment) = .empty;
    for (gen.member_comments) |mc| {
        if (mc.path.len == parent.len + 1 and pathEq(mc.path[0..parent.len], parent)) {
            try out.append(a, mc);
        }
    }
    return out.toOwnedSlice(a);
}

fn pickTarget(a: Allocator, rng: std.Random, gen: GenDoc) !Target {
    switch (rng.intRangeLessThan(u8, 0, 4)) {
        0 => {
            const m = gen.model[rng.uintLessThan(usize, gen.model.len)];
            return .{ .path = m.path, .case_type = .replace };
        },
        1 => {
            const c = gen.containers[rng.uintLessThan(usize, gen.containers.len)];
            var used: std.ArrayList([]const u8) = .empty;
            for (try collectSiblingKeys(a, gen, c)) |k| try used.append(a, k);
            const key = try genUniqueKey(a, rng, &used);
            return .{ .path = try appendSeg(a, c, key), .case_type = .append };
        },
        2 => {
            const c = gen.containers[rng.uintLessThan(usize, gen.containers.len)];
            var first_used: std.ArrayList([]const u8) = .empty;
            for (try collectSiblingKeys(a, gen, c)) |k| try first_used.append(a, k);
            const depth_extra = rng.intRangeAtMost(u8, 1, 3);
            var path: Path = c;
            var j: u8 = 0;
            while (j < depth_extra) : (j += 1) {
                var deeper_used: std.ArrayList([]const u8) = .empty;
                const key = try genUniqueKey(a, rng, if (j == 0) &first_used else &deeper_used);
                path = try appendSeg(a, path, key);
            }
            return .{ .path = path, .case_type = .create };
        },
        else => {
            // Prefer walking through an existing array-valued leaf when one
            // exists: the segment API cannot express an index, so appending
            // a key past an array must hit the object-only intermediate
            // rule and fail cleanly (json's analogue of "array index in a
            // missing tail errors").
            var array_entries: std.ArrayList(ModelEntry) = .empty;
            for (gen.model) |m| {
                if (m.value == .array) try array_entries.append(a, m);
            }
            const base = if (array_entries.items.len > 0 and rng.intRangeLessThan(u8, 0, 10) < 7)
                array_entries.items[rng.uintLessThan(usize, array_entries.items.len)]
            else
                gen.model[rng.uintLessThan(usize, gen.model.len)];
            var used: std.ArrayList([]const u8) = .empty;
            const key = try genUniqueKey(a, rng, &used);
            return .{ .path = try appendSeg(a, base.path, key), .case_type = .walk_leaf };
        },
    }
}

// Read-back / equality helpers

fn resolveSeg(root: json.Value, path: Path) ?json.Value {
    var cur = root;
    for (path) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return cur;
}

/// Deep, order-sensitive equality -- matches `conformance.zig`'s policy:
/// integer/float stay distinct tags, floats compare bit-for-bit, and
/// object member order matters (insertion-ordered, reproduced by parse).
fn valueEql(a: json.Value, b: json.Value) bool {
    if (@as(std.meta.Tag(json.Value), a) != @as(std.meta.Tag(json.Value), b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.float)),
        .number_raw => |x| std.mem.eql(u8, x, b.number_raw),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.len != b.array.len) break :blk false;
            for (x, b.array) |ea, eb| {
                if (!valueEql(ea, eb)) break :blk false;
            }
            break :blk true;
        },
        .object => |x| blk: {
            if (x.count() != b.object.count()) break :blk false;
            for (x.keys(), b.object.keys()) |ka, kb| {
                if (!std.mem.eql(u8, ka, kb)) break :blk false;
            }
            for (x.values(), b.object.values()) |va, vb| {
                if (!valueEql(va, vb)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn emitDoc(a: Allocator, doc: *const json.Document) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    return aw.written();
}

fn renderToString(a: Allocator, value: json.Value) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(a);
    try json.encode(&aw.writer, value, .{});
    return aw.written();
}

fn pathToStr(a: Allocator, path: Path) ![]const u8 {
    if (path.len == 0) return "<root>";
    return std.mem.join(a, " / ", path);
}

fn valueToStr(a: Allocator, value: ?json.Value) []const u8 {
    const v = value orelse return "<none>";
    return renderToString(a, v) catch "<encode failed>";
}

// Failure diagnostics

const Ctx = struct {
    a: Allocator,
    index: usize,
    seed: u64,
    source: []const u8,
    path: Path = &[_][]const u8{},
    value: ?json.Value = null,
    stage: []const u8 = "init",
    output: ?[]const u8 = null,

    fn dump(self: *const Ctx) void {
        std.debug.print(
            "\n=== document_property failure ===\n" ++
                "case index: {d}\n" ++
                "seed: 0x{x}\n" ++
                "stage: {s}\n" ++
                "path: {s}\n" ++
                "value: {s}\n" ++
                "source:\n{s}\n" ++
                "output:\n{s}\n" ++
                "==================================\n",
            .{
                self.index,
                self.seed,
                self.stage,
                pathToStr(self.a, self.path) catch "<path render failed>",
                valueToStr(self.a, self.value),
                self.source,
                self.output orelse "<no output yet>",
            },
        );
    }
};

// Comment multiset matching

/// Non-overlapping occurrence count of `needle` in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |i| {
        count += 1;
        pos = i + needle.len;
    }
    return count;
}

const TextCount = struct { text: []const u8, count: usize };

/// Tally `items` by exact-string identity (distinct token -> occurrence
/// count), so callers can reason about "how many of this comment" rather
/// than just "is this comment present".
fn tally(a: Allocator, items: []const []const u8) ![]TextCount {
    var out: std.ArrayList(TextCount) = .empty;
    outer: for (items) |s| {
        for (out.items) |*tc| {
            if (std.mem.eql(u8, tc.text, s)) {
                tc.count += 1;
                continue :outer;
            }
        }
        try out.append(a, .{ .text = s, .count = 1 });
    }
    return out.toOwnedSlice(a);
}

fn countIn(list: []const TextCount, text: []const u8) usize {
    for (list) |tc| {
        if (std.mem.eql(u8, tc.text, text)) return tc.count;
    }
    return 0;
}

/// Multiset presence check: every distinct comment token generated for the
/// source must still appear in `out` at least as many times as it did in
/// the source, minus however many occurrences of that same token
/// `excluded` names (trivia the edit's documented contract legitimately
/// swept). Matching is by exact delimited token and by count, so one
/// comment's text can't be masked by another's that happens to be a
/// prefix of it, nor can a real drop hide behind a surviving duplicate.
/// Returns the first token found short, or null if all survive.
fn firstLostComment(a: Allocator, source_comments: []const []const u8, excluded: []const []const u8, out: []const u8) !?[]const u8 {
    const expected = try tally(a, source_comments);
    const removed = try tally(a, excluded);
    for (expected) |e| {
        const removed_count = countIn(removed, e.text);
        if (removed_count >= e.count) continue;
        const need = e.count - removed_count;
        if (countOccurrences(out, e.text) < need) return e.text;
    }
    return null;
}

// Per-case invariant checks

fn runRemoveInvariant(a: Allocator, gen: GenDoc, target: Target, post_set_output: []const u8) !void {
    const base_source = if (target.case_type == .replace) gen.source else post_set_output;
    var doc = try json.Document.parse(a, base_source, .{ .dialect = .jsonc });
    try doc.removeSegments(target.path);
    const out = try emitDoc(a, &doc);

    const reparsed = try json.Document.parse(a, out, .{ .dialect = .jsonc });
    if (resolveSeg(reparsed.parsed, target.path) != null) return error.RemoveDidNotRemove;

    for (gen.model) |m| {
        if (pathEq(m.path, target.path)) continue;
        const sv = resolveSeg(reparsed.parsed, m.path) orelse return error.RemoveDroppedSibling;
        if (!valueEql(sv, m.value)) return error.RemoveCorruptedSibling;
    }

    // `remove`'s documented contract deletes a member together with the
    // trivia between it and a neighbor, so the removed member's own
    // leading/trailing comment, plus the adjacent sibling's comment on
    // whichever side the deletion reaches (next sibling's leading comment
    // for a non-last removal; previous sibling's trailing comment when the
    // last member is removed), may legitimately disappear. `.append`
    // targets are always inserted (and here removed) strictly between the
    // previously-last sibling's value and its own trailing trivia, so they
    // have no such original neighbor to exclude. Every other comment must
    // still be present.
    var excluded: std.ArrayList([]const u8) = .empty;
    if (target.case_type == .replace) {
        const parent = target.path[0 .. target.path.len - 1];
        const siblings = try directChildComments(a, gen, parent);
        var idx: usize = 0;
        for (siblings, 0..) |s, si| {
            if (pathEq(s.path, target.path)) {
                idx = si;
                break;
            }
        }
        // Branch-for-branch with `Document.removeSeg`'s object cases:
        // which trivia is swept depends on the removed member's position,
        // not a fixed union of both sides.
        if (siblings.len == 1) {
            // Sole member: the whole interior is wiped.
            if (siblings[idx].leading) |lc| try excluded.append(a, lc);
            if (siblings[idx].trailing) |tc| try excluded.append(a, tc);
        } else if (idx + 1 < siblings.len) {
            // Non-last: deletion runs key -> next key, carrying off this
            // member's own trailing comment and the next member's
            // leading comment. This member's own leading comment sits
            // before the deletion start and must survive.
            if (siblings[idx].trailing) |tc| try excluded.append(a, tc);
            if (siblings[idx + 1].leading) |lc| try excluded.append(a, lc);
        } else {
            // Last (of more than one): deletion runs prev value -> this
            // value, carrying off the previous member's trailing comment
            // and this member's own leading comment. This member's own
            // trailing comment sits after the deletion end and must
            // survive.
            if (siblings[idx].leading) |lc| try excluded.append(a, lc);
            if (siblings[idx - 1].trailing) |tc| try excluded.append(a, tc);
        }
    }
    if (try firstLostComment(a, gen.comments, excluded.items, out)) |_| return error.RemoveLostComment;
}

fn runCase(gpa: Allocator, seed: u64, index: usize) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    const gen = try genDoc(a, rng);

    var ctx: Ctx = .{ .a = a, .index = index, .seed = seed, .source = gen.source };
    errdefer ctx.dump();

    ctx.stage = "select target";
    const target = try pickTarget(a, rng, gen);
    ctx.path = target.path;

    ctx.stage = "generate edit value";
    const edit_value = try genEditValue(a, rng);
    ctx.value = edit_value;

    var doc = try json.Document.parse(a, gen.source, .{ .dialect = .jsonc });

    ctx.stage = "apply set";
    if (doc.setValueSegments(target.path, edit_value)) |_| {
        ctx.stage = "post-set emit";
        const out1 = try emitDoc(a, &doc);
        ctx.output = out1;

        ctx.stage = "reparse-clean (invariant 2)";
        const reparsed = try json.Document.parse(a, out1, .{ .dialect = .jsonc });

        ctx.stage = "read-back exact (invariant 3)";
        const got = resolveSeg(reparsed.parsed, target.path) orelse return error.PathMissingAfterSet;
        if (!valueEql(got, edit_value)) return error.ReadBackMismatch;

        ctx.stage = "sibling preservation (invariant 4)";
        for (gen.model) |m| {
            if (pathEq(m.path, target.path)) continue;
            const sv = resolveSeg(reparsed.parsed, m.path) orelse return error.SiblingMissing;
            if (!valueEql(sv, m.value)) return error.SiblingMismatch;
        }

        ctx.stage = "comment preservation (invariant 5)";
        if (try firstLostComment(a, gen.comments, &[_][]const u8{}, out1)) |_| return error.CommentLost;

        if (target.case_type == .replace) {
            ctx.stage = "byte-exact-except-value (invariant 5b)";
            const entry = findModelEntry(gen.model, target.path).?;
            const predicted_value_bytes = try renderToString(a, edit_value);
            const expected = try std.mem.concat(a, u8, &.{
                gen.source[0..entry.span.start],
                predicted_value_bytes,
                gen.source[entry.span.end..],
            });
            if (!std.mem.eql(u8, expected, out1)) return error.NotMinimalDiff;
        }

        ctx.stage = "idempotence (invariant 6)";
        try doc.setValueSegments(target.path, edit_value);
        const out2 = try emitDoc(a, &doc);
        ctx.output = out2;
        if (!std.mem.eql(u8, out1, out2)) return error.NotIdempotent;

        if (target.case_type == .replace or target.case_type == .append) {
            ctx.stage = "remove round-trip (invariant 7)";
            try runRemoveInvariant(a, gen, target, out1);
        }
    } else |_| {
        ctx.stage = "clean error rollback (invariant 1)";
        if (!std.mem.eql(u8, gen.source, doc.source)) return error.NotByteUnchangedOnError;
    }
}

test "document property battery: 7 invariants over deterministic generated documents" {
    const gpa = testing.allocator;
    var i: usize = 0;
    while (i < case_count) : (i += 1) {
        const seed = base_seed +% @as(u64, i);
        try runCase(gpa, seed, i);
    }
}
