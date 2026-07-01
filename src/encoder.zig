//! Plain-JSON encoder.
//!
//! Walks a `Value` tree and writes RFC 8259 JSON to a `std.Io.Writer`.
//! Output is always plain JSON -- no comments, no trailing commas --
//! regardless of the dialect the tree was parsed from. Objects emit
//! members in insertion order. Strings pass non-ASCII bytes through
//! raw (UTF-8 output); only `"`, `\`, and control bytes are escaped.
//!
//! `encodeTyped` walks a typed Zig value directly instead, consulting
//! the same `json_*` annotations and hooks as typed decoding.
//!
//! Floats: zero and values with |x| in [1e-6, 1e21) use shortest
//! round-trip decimal notation; values outside that range use shortest
//! scientific notation. Integer-valued decimal outputs get a `.0` suffix
//! so they re-parse as `.float`, not `.integer`. NaN and +/-Inf have no
//! JSON representation and yield `error.UnrepresentableFloat`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const lex = @import("lex.zig");
const value_mod = @import("value.zig");
const decode_mod = @import("decode.zig");

pub const Value = value_mod.Value;

/// Writer failures, plus `UnrepresentableFloat` when a `.float` holds
/// NaN or +/-Inf (JSON has no token for them; such values can enter a
/// tree via the parser's overflow-to-inf number fallback).
/// `NestingTooDeep` fires when a hand-built `Value` tree exceeds
/// `max_encode_depth` levels of array/object nesting. `OutOfMemory`
/// arises only from `encodeTyped`'s `toJson` hooks, which build their
/// `Value` in the caller's arena.
pub const EncodeError = Io.Writer.Error || error{ UnrepresentableFloat, NestingTooDeep, OutOfMemory };

pub const PrettyOptions = struct { indent: usize = 2 };

/// Maximum array/object nesting depth. `writeValue` recurses one host
/// stack frame per level, so this is the stack-safe ceiling shared with
/// the recursive parser and document builder: a hand-built `Value` nested
/// deeper yields `error.NestingTooDeep`, never a stack overflow.
const max_encode_depth = value_mod.recursive_depth_ceiling;

/// Encode `value` as compact JSON to `w`: no whitespace anywhere,
/// object members in insertion order. Returns `error.NestingTooDeep`
/// when array/object nesting exceeds `max_encode_depth` (128).
///
/// Precondition: every `.string` byte slice must be valid UTF-8 (GIGO).
/// The encoder passes string bytes through without validation, so a
/// hand-built `Value{ .string = "\xff" }` emits invalid JSON; values
/// produced by `parse` already satisfy this. No runtime check is done.
pub fn encode(w: *Io.Writer, value: Value) EncodeError!void {
    try writeValue(w, value, null, 0);
}

/// Encode `value` as pretty-printed JSON: members one per line,
/// indented `options.indent` spaces per nesting level, `"key": value`
/// with a space after the colon, closing bracket on its own line at
/// the parent's indent. Empty containers emit `{}`/`[]` inline.
/// Returns `error.NestingTooDeep` when nesting exceeds `max_encode_depth`
/// (128).
pub fn encodePretty(w: *Io.Writer, value: Value, options: PrettyOptions) EncodeError!void {
    try writeValue(w, value, options.indent, 0);
}

/// Encode a typed Zig value as compact JSON, consulting the same
/// `json_rename` / `json_skip` / `json_flatten` / `json_tag` annotations
/// and `toJson` hooks that typed decoding consults, so output decodes
/// back via `parseInto(T, ...)`.
///
/// Annotations and hooks are read from `@TypeOf(value)`. Bind an
/// anonymous struct literal to the annotated type before passing it:
/// an anonymous literal has its own type, which carries no declarations,
/// so annotation-driven behavior would silently not apply.
///
/// Integer round-trip: integer fields are emitted at full width, so a
/// u64 field emits all 64 bits (e.g. "18446744073709551615"). `parseInto`
/// recovers them losslessly for any target fitting within i128. For u128
/// fields or values beyond i128 range, use `number_mode = .raw` on the
/// decode side to parse the lexeme directly. Null optional fields are
/// omitted from objects entirely (decode maps absent to null). Enums emit
/// their tag name as a string. Tagged unions emit the discriminator member
/// first, then the payload's fields inline in the same object. Embedded
/// `Value` fields encode dynamically. NaN and +/-Inf floats yield
/// `error.UnrepresentableFloat`; `arena` only backs `toJson` hook values.
///
/// Wide-integer boundary: a u128 value above i128 max
/// (170141183460469231731687303715884105727) is emitted correctly as a
/// decimal literal (e.g. "340282366920938463463374607431768211455"), but
/// the default `parseInto` path -- which materializes integers as `.integer`
/// (i128) -- cannot represent it and falls back to `.float`, losing
/// precision. Round-tripping such a value requires `number_mode = .raw` on
/// the decode side, targeting a type wide enough (e.g. u128 or a custom
/// `fromJson` hook).
pub fn encodeTyped(w: *std.Io.Writer, value: anytype, arena: std.mem.Allocator) EncodeError!void {
    const T = @TypeOf(value);
    try writeTypedValue(T, value, w, arena, 0);
}

fn writeTypedValue(comptime T: type, value: T, w: *Io.Writer, arena: std.mem.Allocator, depth: usize) EncodeError!void {
    if (depth > max_encode_depth) return error.NestingTooDeep;
    if (T == Value) return writeValue(w, value, null, depth);

    // Custom toJson hook short-circuit, symmetric with decode's fromJson.
    if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "toJson"))) {
        comptime {
            const fn_info = @typeInfo(@TypeOf(T.toJson)).@"fn";
            if (fn_info.params.len != 2) {
                @compileError(@typeName(T) ++ ".toJson must take exactly 2 params: (Self, Allocator)");
            }
        }
        const hooked = T.toJson(value, arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        return writeValue(w, hooked, null, depth);
    }

    if (comptime (@typeInfo(T) == .@"union" and @hasDecl(T, "json_tag"))) {
        return writeTypedTaggedUnion(T, value, w, arena, depth);
    }

    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int => try w.print("{d}", .{value}),
        .float => try writeFloat(w, @floatCast(value)),
        .pointer => |p| {
            if (p.size != .slice) @compileError("json encodeTyped: only slice pointers supported, got " ++ @typeName(T));
            if (p.child == u8 and p.is_const) return writeQuotedString(w, value);
            try writeTypedArray(p.child, value, w, arena, depth);
        },
        .array => |a| try writeTypedArray(a.child, &value, w, arena, depth),
        .optional => |o| {
            // A null optional reaching this point sits inside an array (or
            // at the root), where there is no object member to omit, so it
            // emits JSON null. Struct fields omit null optionals upstream.
            if (value) |inner| {
                try writeTypedValue(o.child, inner, w, arena, depth);
            } else {
                try w.writeAll("null");
            }
        },
        .@"struct" => {
            comptime decode_mod.validateAnnotations(T);
            try w.writeByte('{');
            var first = true;
            try writeTypedStructFields(T, value, w, arena, depth, &first);
            try w.writeByte('}');
        },
        .@"enum" => try writeQuotedString(w, @tagName(value)),
        else => @compileError("json encodeTyped: unsupported type " ++ @typeName(T)),
    }
}

fn writeTypedArray(comptime Child: type, items: []const Child, w: *Io.Writer, arena: std.mem.Allocator, depth: usize) EncodeError!void {
    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try writeTypedValue(Child, item, w, arena, depth + 1);
    }
    try w.writeByte(']');
}

/// Emits the members of `value` without the surrounding braces, so that
/// flattened fields and tagged-union payloads inline into the parent
/// object. `first` carries comma state across recursion levels.
fn writeTypedStructFields(comptime T: type, value: T, w: *Io.Writer, arena: std.mem.Allocator, depth: usize, first: *bool) EncodeError!void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime decode_mod.isSkipped(T, field.name)) continue;
        const fv = @field(value, field.name);
        if (comptime decode_mod.isFlattened(T, field.name)) {
            comptime decode_mod.validateAnnotations(field.type);
            try writeTypedStructFields(field.type, fv, w, arena, depth, first);
        } else if (comptime @typeInfo(field.type) == .optional) {
            // Null optionals are omitted; decode maps the absent key back
            // to null, so the round-trip is lossless.
            if (fv) |inner| {
                try writeTypedMember(w, comptime decode_mod.renamedKey(T, field.name), first);
                try writeTypedValue(@typeInfo(field.type).optional.child, inner, w, arena, depth + 1);
            }
        } else {
            try writeTypedMember(w, comptime decode_mod.renamedKey(T, field.name), first);
            try writeTypedValue(field.type, fv, w, arena, depth + 1);
        }
    }
}

fn writeTypedMember(w: *Io.Writer, key: []const u8, first: *bool) EncodeError!void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try writeQuotedString(w, key);
    try w.writeByte(':');
}

fn writeTypedTaggedUnion(comptime T: type, value: T, w: *Io.Writer, arena: std.mem.Allocator, depth: usize) EncodeError!void {
    comptime decode_mod.validateAnnotations(T);
    const active = std.meta.activeTag(value);
    try w.writeByte('{');
    inline for (@typeInfo(T).@"union".fields) |union_field| {
        if (active == @field(std.meta.Tag(T), union_field.name)) {
            try writeQuotedString(w, T.json_tag);
            try w.writeByte(':');
            try writeQuotedString(w, comptime decode_mod.renamedKey(T, union_field.name));
            if (union_field.type != void) {
                // Discriminator member is already written, so payload
                // members all get a leading comma.
                var first = false;
                try writeTypedStructFields(union_field.type, @field(value, union_field.name), w, arena, depth, &first);
            }
        }
    }
    try w.writeByte('}');
}

/// `indent` null means compact mode; `depth` tracks nesting for both
/// indentation and the `max_encode_depth` guard.
fn writeValue(w: *Io.Writer, val: Value, indent: ?usize, depth: usize) EncodeError!void {
    if (depth > max_encode_depth) return error.NestingTooDeep;
    switch (val) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloat(w, f),
        // Verbatim preserved lexeme (raw number mode): emit byte-for-byte.
        .number_raw => |raw| try w.writeAll(raw),
        .string => |s| try writeQuotedString(w, s),
        .array => |arr| {
            if (arr.len == 0) return w.writeAll("[]");
            try w.writeByte('[');
            for (arr, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try newlineIndent(w, indent, depth + 1);
                try writeValue(w, item, indent, depth + 1);
            }
            try newlineIndent(w, indent, depth);
            try w.writeByte(']');
        },
        .object => |obj| {
            if (obj.count() == 0) return w.writeAll("{}");
            try w.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;
                try newlineIndent(w, indent, depth + 1);
                try writeQuotedString(w, entry.key_ptr.*);
                try w.writeByte(':');
                if (indent != null) try w.writeByte(' ');
                try writeValue(w, entry.value_ptr.*, indent, depth + 1);
            }
            try newlineIndent(w, indent, depth);
            try w.writeByte('}');
        },
    }
}

fn newlineIndent(w: *Io.Writer, indent: ?usize, depth: usize) EncodeError!void {
    const n = indent orelse return;
    try w.writeByte('\n');
    try w.splatByteAll(' ', n * depth);
}

fn writeQuotedString(w: *Io.Writer, s: []const u8) EncodeError!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        // The bytes to escape on encode are exactly the bytes that stop a
        // string scan on parse (`"`, `\`, controls), so the lexer's SIMD
        // scanner doubles as the escape scan.
        const skip = lex.scanStringFast(s[i..]);
        if (skip > 0) {
            try w.writeAll(s[i .. i + skip]);
            i += skip;
            if (i >= s.len) break;
        }
        switch (s[i]) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x09 => try w.writeAll("\\t"),
            0x0A => try w.writeAll("\\n"),
            0x0C => try w.writeAll("\\f"),
            0x0D => try w.writeAll("\\r"),
            else => |c| try w.print("\\u{x:0>4}", .{c}),
        }
        i += 1;
    }
    try w.writeByte('"');
}

/// Shortest round-trip form (ryu via `std.fmt.float`). Scientific mode
/// for values with |x| outside [1e-6, 1e21) (excluding zero); decimal
/// mode otherwise, with a `.0` suffix when the decimal digits carry no
/// `.`/`e` marker so the output re-parses as `.float`, not `.integer`.
fn writeFloat(w: *Io.Writer, f: f64) EncodeError!void {
    if (std.math.isNan(f) or std.math.isInf(f)) return error.UnrepresentableFloat;
    const a = @abs(f);
    if (a != 0 and (a < 1e-6 or a >= 1e21)) {
        var buf: [std.fmt.float.bufferSize(.scientific, f64)]u8 = undefined;
        const s = std.fmt.float.render(&buf, f, .{ .mode = .scientific }) catch unreachable;
        return w.writeAll(s); // scientific output always contains 'e': re-parses as float
    }
    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    const s = std.fmt.float.render(&buf, f, .{ .mode = .decimal }) catch unreachable;
    try w.writeAll(s);
    for (s) |c| {
        if (c == '.' or c == 'e' or c == 'E') return;
    }
    try w.writeAll(".0");
}

const parse = @import("parser.zig").parse;
const parseInto = decode_mod.parseInto;

test "encode compact canonical" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "{ \"b\" : [ 1 , 2.5 , null ] , \"s\" : \"q\\\"\" }", .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, v);
    try std.testing.expectEqualStrings("{\"b\":[1,2.5,null],\"s\":\"q\\\"\"}", aw.written());
}

test "raw number round-trips through encode verbatim" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{\"a\":123456789012345678901234567890,\"b\":1e2,\"c\":1.50}";
    const v = try parse(a, src, .{ .number_mode = .raw });
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, v);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "encode pretty with indent" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "{\"a\":[1]}", .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encodePretty(&aw.writer, v, .{ .indent = 2 });
    try std.testing.expectEqualStrings("{\n  \"a\": [\n    1\n  ]\n}", aw.written());
}

test "encode escapes control chars and preserves unicode" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, .{ .string = "\x01\n\xe3\x81\x82" });
    try std.testing.expectEqualStrings("\"\\u0001\\n\xe3\x81\x82\"", aw.written());
}

test "float encoding round-trips" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, .{ .float = 0.1 });
    const back = try parse(a, aw.written(), .{});
    try std.testing.expectEqual(@as(f64, 0.1), back.float);
}

test "encode pretty three levels deep" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "{\"a\":{\"b\":[1,{\"c\":true}]}}", .{});
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encodePretty(&aw.writer, v, .{ .indent = 2 });
    const expected =
        "{\n" ++
        "  \"a\": {\n" ++
        "    \"b\": [\n" ++
        "      1,\n" ++
        "      {\n" ++
        "        \"c\": true\n" ++
        "      }\n" ++
        "    ]\n" ++
        "  }\n" ++
        "}";
    try testing.expectEqualStrings(expected, aw.written());
}

test "encode empty containers compact and pretty" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "{\"o\":{},\"a\":[]}", .{});

    var compact: Io.Writer.Allocating = .init(a);
    defer compact.deinit();
    try encode(&compact.writer, v);
    try testing.expectEqualStrings("{\"o\":{},\"a\":[]}", compact.written());

    var pretty: Io.Writer.Allocating = .init(a);
    defer pretty.deinit();
    try encodePretty(&pretty.writer, v, .{ .indent = 2 });
    try testing.expectEqualStrings("{\n  \"o\": {},\n  \"a\": []\n}", pretty.written());

    var root_obj: Io.Writer.Allocating = .init(a);
    defer root_obj.deinit();
    try encodePretty(&root_obj.writer, .{ .object = .empty }, .{ .indent = 2 });
    try testing.expectEqualStrings("{}", root_obj.written());

    var root_arr: Io.Writer.Allocating = .init(a);
    defer root_arr.deinit();
    try encodePretty(&root_arr.writer, .{ .array = &.{} }, .{ .indent = 2 });
    try testing.expectEqualStrings("[]", root_arr.written());
}

test "encode escapes keys and round-trips them" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "{\"a\\\"b\": 1}", .{});
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, v);
    try testing.expectEqualStrings("{\"a\\\"b\":1}", aw.written());
    const back = try parse(a, aw.written(), .{});
    try testing.expectEqual(@as(i64, 1), back.object.get("a\"b").?.integer);
}

test "encode deep array compact" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "[[[[[1,2],[3]],[]],[4]],5]", .{});
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, v);
    try testing.expectEqualStrings("[[[[[1,2],[3]],[]],[4]],5]", aw.written());
}

test "encode rejects NaN and infinities" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try testing.expectError(error.UnrepresentableFloat, encode(&aw.writer, .{ .float = std.math.nan(f64) }));
    try testing.expectError(error.UnrepresentableFloat, encode(&aw.writer, .{ .float = std.math.inf(f64) }));
    try testing.expectError(error.UnrepresentableFloat, encode(&aw.writer, .{ .float = -std.math.inf(f64) }));

    // Inf reaches real trees via the parser's overflow-to-float fallback.
    const v = try parse(a, "1e309", .{});
    try testing.expect(std.math.isPositiveInf(v.float));
    try testing.expectError(error.UnrepresentableFloat, encode(&aw.writer, v));
}

test "encode integer extremes" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, .{ .integer = std.math.maxInt(i64) });
    try testing.expectEqualStrings("9223372036854775807", aw.written());
    aw.clearRetainingCapacity();
    try encode(&aw.writer, .{ .integer = std.math.minInt(i64) });
    try testing.expectEqualStrings("-9223372036854775808", aw.written());
    aw.clearRetainingCapacity();
    try encode(&aw.writer, .{ .integer = std.math.maxInt(i128) });
    try testing.expectEqualStrings("170141183460469231731687303715884105727", aw.written());
    aw.clearRetainingCapacity();
    try encode(&aw.writer, .{ .integer = std.math.minInt(i128) });
    try testing.expectEqualStrings("-170141183460469231731687303715884105728", aw.written());
}

test "encode integer-valued float re-parses as float" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, .{ .float = 1.0 });
    try testing.expectEqualStrings("1.0", aw.written());
    const back = try parse(a, aw.written(), .{});
    try testing.expect(back == .float);
    try testing.expectEqual(@as(f64, 1.0), back.float);
}

test "encode float extremes round-trip" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const extremes = [_]f64{
        std.math.floatMax(f64),
        std.math.floatMin(f64),
        std.math.floatTrueMin(f64),
        -std.math.floatMax(f64),
        1e300,
        -2.2250738585072014e-308,
    };
    for (extremes) |f| {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, .{ .float = f });
        const back = try parse(a, aw.written(), .{});
        try testing.expect(back == .float);
        try testing.expectEqual(f, back.float);
    }
}

test "encode multi-byte unicode past the SIMD lane boundary" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // 18 plain bytes (incl. multi-byte UTF-8), then an escape at index 18,
    // i.e. past the first 16-byte vector lane.
    const s = "abcdefghijkl\xe3\x81\x82xy\ntail\xe3\x81\x84";
    comptime std.debug.assert(std.mem.indexOfScalar(u8, s, '\n').? > 16);
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, .{ .string = s });
    try testing.expectEqualStrings("\"abcdefghijkl\xe3\x81\x82xy\\ntail\xe3\x81\x84\"", aw.written());
}

test "escape scan matches byte-loop on every stop byte" {
    const fixtures = [_][]const u8{
        "hello",
        "hello\\world",
        "hello\"world",
        "hello\nworld",
        "hello\x01world",
        "hello\x1fworld",
        "abcdefghijklmnopqrstuvwxyz", // long plain
        "abcdefghijklmnop\"rest", // stop exactly at lane boundary (idx 16)
        "abcdefghijklmnopq\\rest", // stop one past lane boundary (idx 17)
        "",
    };
    for (fixtures) |f| {
        const fast = lex.scanStringFast(f);
        var slow: usize = 0;
        while (slow < f.len) : (slow += 1) {
            const c = f[slow];
            if (c == '"' or c == '\\' or c < 0x20) break;
        }
        try testing.expectEqual(slow, fast);
    }
}

test "encode escapes all 32 control bytes" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var c: u8 = 0;
    while (c < 0x20) : (c += 1) {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, .{ .string = &.{c} });
        const out = aw.written();
        try testing.expect(out.len >= 4);
        try testing.expectEqual(@as(u8, '\\'), out[1]);
        // Round-trip through the parser restores the exact byte.
        const back = try parse(a, out, .{});
        try testing.expectEqualStrings(&.{c}, back.string);
    }
}

test "float notation thresholds" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // Boundary at 1e21: >= 1e21 goes scientific, < 1e21 stays decimal.
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, .{ .float = 1e21 });
        try testing.expectEqualStrings("1e21", aw.written());
    }
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, .{ .float = 1e20 });
        // 1e20 is integer-valued; decimal render has no '.', so the .0 suffix is appended.
        try testing.expectEqualStrings("100000000000000000000.0", aw.written());
    }

    // Boundary at 1e-6: >= 1e-6 stays decimal, < 1e-6 goes scientific.
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, .{ .float = 1e-6 });
        try testing.expectEqualStrings("0.000001", aw.written());
    }
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, .{ .float = 1e-7 });
        try testing.expectEqualStrings("1e-7", aw.written());
    }

    // Extreme values encode to short scientific and round-trip.
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, .{ .float = 1e300 });
        try testing.expectEqualStrings("1e300", aw.written());
        const back = try parse(a, aw.written(), .{});
        try testing.expectEqual(@as(f64, 1e300), back.float);
    }
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, .{ .float = 5e-324 });
        try testing.expectEqualStrings("5e-324", aw.written());
        const back = try parse(a, aw.written(), .{});
        try testing.expectEqual(@as(f64, 5e-324), back.float);
    }

    // Negative zero encodes with decimal path (abs == 0), keeps sign.
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, .{ .float = -0.0 });
        try testing.expectEqualStrings("-0.0", aw.written());
    }
}

test "encode nesting depth guard" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // Build a 200-deep array chain: each element is a single-element array,
    // except the innermost which holds null. Exceeds max_encode_depth (128).
    var inner: Value = .null;
    var depth: usize = 0;
    while (depth < 200) : (depth += 1) {
        const arr = try a.alloc(Value, 1);
        arr[0] = inner;
        inner = .{ .array = arr };
    }

    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try testing.expectError(error.NestingTooDeep, encode(&aw.writer, inner));
    }
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try testing.expectError(error.NestingTooDeep, encodePretty(&aw.writer, inner, .{}));
    }

    // A 100-deep chain is within the limit and succeeds.
    var shallow: Value = .null;
    depth = 0;
    while (depth < 100) : (depth += 1) {
        const arr = try a.alloc(Value, 1);
        arr[0] = shallow;
        shallow = .{ .array = arr };
    }
    {
        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try encode(&aw.writer, shallow); // must not error
    }
}

test "encode of a very deep Value yields NestingTooDeep, never overflows the stack" {
    // A 200k-deep hand-built array chain. The guard fires at the ceiling,
    // so writeValue returns before recursing past it -- no SIGSEGV.
    // (Run under ReleaseSafe to confirm.)
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var inner: Value = .null;
    var depth: usize = 0;
    while (depth < 200_000) : (depth += 1) {
        const arr = try a.alloc(Value, 1);
        arr[0] = inner;
        inner = .{ .array = arr };
    }
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try testing.expectError(error.NestingTooDeep, encode(&aw.writer, inner));
}

test "encode hand-built ObjectMap insertion order" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const ObjectMap = value_mod.ObjectMap;

    var map: ObjectMap = .empty;
    try map.put(a, "z", .{ .integer = 1 });
    try map.put(a, "a", .{ .integer = 2 });
    try map.put(a, "m", .{ .integer = 3 });

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encode(&aw.writer, .{ .object = map });
    // Insertion order: z, a, m.
    try testing.expectEqualStrings("{\"z\":1,\"a\":2,\"m\":3}", aw.written());
}

test "encode key with embedded quote via pretty path" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const ObjectMap = value_mod.ObjectMap;

    var map: ObjectMap = .empty;
    // Key is a"b (contains a literal double-quote).
    try map.put(a, "a\"b", .{ .integer = 42 });

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encodePretty(&aw.writer, .{ .object = map }, .{ .indent = 2 });
    const out = aw.written();
    // The key must be escaped as \"a\\\"b\" in the output line.
    try testing.expect(std.mem.indexOf(u8, out, "\"a\\\"b\"") != null);
}

test "encodeTyped honors annotations symmetric with decode" {
    const C = struct {
        pub const json_rename = .{ .listen_addr = "listen-addr" };
        pub const json_skip = .{"runtime"};
        listen_addr: []const u8,
        runtime: u32 = 0,
        port: u16,
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const cfg: C = .{ .listen_addr = "x", .port = 1 };
    try encodeTyped(&aw.writer, cfg, a);
    try std.testing.expectEqualStrings("{\"listen-addr\":\"x\",\"port\":1}", aw.written());
}

test "typed round-trip" {
    const C = struct { name: []const u8, tags: []const []const u8 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const orig: C = .{ .name = "n", .tags = &.{ "a", "b" } };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encodeTyped(&aw.writer, orig, a);
    const back = try parseInto(C, a, aw.written(), .{});
    try std.testing.expectEqualStrings("n", back.name);
    try std.testing.expectEqualStrings("b", back.tags[1]);
}

test "encodeTyped: json_flatten inlines inner fields" {
    const Inner = struct { x: u32, y: u32 };
    const Outer = struct {
        pub const json_flatten = .{"inner"};
        name: []const u8,
        inner: Inner,
    };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const outer: Outer = .{ .name = "foo", .inner = .{ .x = 1, .y = 2 } };
    try encodeTyped(&aw.writer, outer, a);
    try testing.expectEqualStrings("{\"name\":\"foo\",\"x\":1,\"y\":2}", aw.written());
}

test "encodeTyped: tagged union emits discriminator first" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        http: struct { port: u16, secure: bool = false },
        none,
    };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const http: Plugin = .{ .http = .{ .port = 80 } };
    try encodeTyped(&aw.writer, http, a);
    try testing.expectEqualStrings("{\"kind\":\"http\",\"port\":80,\"secure\":false}", aw.written());

    aw.clearRetainingCapacity();
    const none: Plugin = .none;
    try encodeTyped(&aw.writer, none, a);
    try testing.expectEqualStrings("{\"kind\":\"none\"}", aw.written());
}

test "encodeTyped: enum emits tag name string" {
    const C = struct { mode: enum { fast, slow } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .mode = .slow };
    try encodeTyped(&aw.writer, c, a);
    try testing.expectEqualStrings("{\"mode\":\"slow\"}", aw.written());
}

test "encodeTyped: toJson hook overrides built-in encoding" {
    const SemVer = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn toJson(self: @This(), arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
            const s = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
            return .{ .string = s };
        }
    };
    const C = struct { v: SemVer };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .v = .{ .major = 1, .minor = 2, .patch = 3 } };
    try encodeTyped(&aw.writer, c, a);
    try testing.expectEqualStrings("{\"v\":\"1.2.3\"}", aw.written());
}

test "encodeTyped: null optional omitted, non-null present" {
    const C = struct { a: ?u32, b: ?u32 };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .a = null, .b = 2 };
    try encodeTyped(&aw.writer, c, a);
    try testing.expectEqualStrings("{\"b\":2}", aw.written());

    // The omitted key decodes back to null: lossless round-trip.
    const back = try parseInto(C, a, aw.written(), .{});
    try testing.expectEqual(@as(?u32, null), back.a);
    try testing.expectEqual(@as(?u32, 2), back.b);
}

test "encodeTyped: embedded Value encodes dynamically" {
    const C = struct { meta: Value, n: u32 };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const meta = try parse(a, "{\"a\":[1,2]}", .{});
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .meta = meta, .n = 5 };
    try encodeTyped(&aw.writer, c, a);
    try testing.expectEqualStrings("{\"meta\":{\"a\":[1,2]},\"n\":5}", aw.written());
}

test "encodeTyped: NaN float is unrepresentable" {
    const C = struct { x: f64 };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .x = std.math.nan(f64) };
    try testing.expectError(error.UnrepresentableFloat, encodeTyped(&aw.writer, c, a));
}

test "encodeTyped: fixed array encodes as JSON array" {
    const C = struct { rgb: [3]u8 };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .rgb = .{ 1, 2, 3 } };
    try encodeTyped(&aw.writer, c, a);
    try testing.expectEqualStrings("{\"rgb\":[1,2,3]}", aw.written());
}

test "encodeTyped: full annotation round-trip" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        pub const json_rename = .{ .http_server = "http" };
        http_server: struct { port: u16 },
        none,
    };
    const C = struct {
        pub const json_rename = .{ .listen_addr = "listen-addr" };
        pub const json_skip = .{"runtime"};
        pub const json_flatten = .{"common"};
        listen_addr: []const u8,
        runtime: u32 = 7,
        common: struct { verbose: bool = false },
        plugin: Plugin,
    };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const orig: C = .{
        .listen_addr = "x",
        .common = .{ .verbose = true },
        .plugin = .{ .http_server = .{ .port = 80 } },
    };
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encodeTyped(&aw.writer, orig, a);
    try testing.expectEqualStrings(
        "{\"listen-addr\":\"x\",\"verbose\":true,\"plugin\":{\"kind\":\"http\",\"port\":80}}",
        aw.written(),
    );

    const back = try parseInto(C, a, aw.written(), .{});
    try testing.expectEqualStrings("x", back.listen_addr);
    try testing.expectEqual(@as(u32, 7), back.runtime);
    try testing.expectEqual(true, back.common.verbose);
    try testing.expectEqual(@as(u16, 80), back.plugin.http_server.port);
}
