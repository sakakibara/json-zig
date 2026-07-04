//! Typed decoding from `Value` into native Zig types.
//!
//! Maps a parsed JSON `Value` tree onto a target struct via comptime
//! reflection, the way `serde::Deserialize` does in Rust. Strings and slices
//! are zero-copy where possible; everything else lives in the caller's arena.
//!
//! ```zig
//! const Config = struct {
//!     title: []const u8,
//!     port: u16 = 8080,
//!     tags: []const []const u8,
//!     server: struct {
//!         host: []const u8,
//!         tls: bool = false,
//!     },
//! };
//!
//! const cfg = try json.parseInto(Config, arena, src, .{});
//! ```
//!
//! Field defaults satisfy missing-field cases. Optional fields (`?T`) become
//! `null` when absent or explicitly `null`. Unknown JSON keys are an error by
//! default; opt out with `ParseOptions{ .ignore_unknown_fields = true }`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const parser_mod = @import("parser.zig");
const lev = @import("levenshtein.zig");

pub const DecodeError = error{
    TypeMismatch,
    MissingField,
    UnknownField,
    InvalidEnumValue,
    Overflow,
    OutOfMemory,
};

/// Decode diagnostics have no source location (the value tree carries none),
/// so every entry gets a zero span and the dotted path is folded into the
/// message text instead.
const no_span: value_mod.Span = .{ .start = 0, .end = 0 };

fn appendDiag(list: *std.ArrayList(parser_mod.Diagnostic), arena: Allocator, path: *const PathBuilder, msg: []const u8, suggestion: ?[]const u8) Allocator.Error!void {
    const full = if (path.slice().len > 0)
        try std.fmt.allocPrint(arena, "{s} (at {s})", .{ msg, path.slice() })
    else
        msg;
    try list.append(arena, .{ .message = full, .span = no_span, .suggestion = suggestion });
}

const PathBuilder = struct {
    buf: std.ArrayList(u8),

    pub fn pushSegment(self: *PathBuilder, arena: Allocator, segment: []const u8) Allocator.Error!usize {
        const prev = self.buf.items.len;
        if (prev > 0) try self.buf.append(arena, '.');
        try self.buf.appendSlice(arena, segment);
        return prev;
    }

    pub fn pushIndex(self: *PathBuilder, arena: Allocator, idx: usize) Allocator.Error!usize {
        const prev = self.buf.items.len;
        var tmp: [24]u8 = undefined;
        // [24]u8 fits '[' + max u64 decimal (20 digits) + ']' + NUL -- always in range.
        const s = std.fmt.bufPrint(&tmp, "[{d}]", .{idx}) catch unreachable;
        try self.buf.appendSlice(arena, s);
        return prev;
    }

    pub fn restore(self: *PathBuilder, prev_len: usize) void {
        self.buf.shrinkRetainingCapacity(prev_len);
    }

    pub fn slice(self: *const PathBuilder) []const u8 {
        return self.buf.items;
    }
};

/// Comptime check that every annotation entry on `T` names a real field
/// (struct) or variant (union): `json_rename` keys, `json_skip` entries,
/// and `json_flatten` entries. A typo'd annotation fails the build with
/// `@compileError` instead of silently never applying. Runs at the top of
/// struct and tagged-union decoding (and typed encoding). Compile errors
/// cannot be asserted from the test suite.
pub fn validateAnnotations(comptime T: type) void {
    comptime {
        const kind = if (@typeInfo(T) == .@"union") "variant" else "field";
        if (@hasDecl(T, "json_rename")) {
            for (@typeInfo(@TypeOf(T.json_rename)).@"struct".fields) |rf| {
                if (!@hasField(T, rf.name)) {
                    @compileError("json_rename entry `" ++ rf.name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                }
            }
        }
        if (@hasDecl(T, "json_skip")) {
            for (T.json_skip) |name| {
                if (!@hasField(T, name)) {
                    @compileError("json_skip entry `" ++ name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                }
            }
        }
        if (@hasDecl(T, "json_flatten")) {
            for (T.json_flatten) |name| {
                if (!@hasField(T, name)) {
                    @compileError("json_flatten entry `" ++ name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                }
            }
        }
    }
}

/// Returns the effective JSON key for `field_name` on type `T`,
/// consulting `T.json_rename` if present.
pub fn renamedKey(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (!@hasDecl(T, "json_rename")) return field_name;
    const renames = T.json_rename;
    if (@hasField(@TypeOf(renames), field_name)) {
        return @field(renames, field_name);
    }
    return field_name;
}

/// Returns true if `field_name` on type `T` is listed in `T.json_skip`.
pub fn isSkipped(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "json_skip")) return false;
    const skip = T.json_skip;
    inline for (skip) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

/// Returns true if `field_name` on type `T` is listed in `T.json_flatten`.
pub fn isFlattened(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "json_flatten")) return false;
    const flat = T.json_flatten;
    inline for (flat) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

/// Returns the full set of JSON keys that decoding `T` expects to see
/// at the object's level -- i.e., renamed names for non-flattened fields,
/// plus the expectedKeys of each flattened field's type (recursive).
fn expectedKeys(comptime T: type) []const []const u8 {
    comptime {
        const s = @typeInfo(T).@"struct";
        var keys: []const []const u8 = &.{};
        for (s.fields) |field| {
            if (isSkipped(T, field.name)) continue;
            if (isFlattened(T, field.name)) {
                const inner = expectedKeys(field.type);
                keys = keys ++ inner;
            } else {
                keys = keys ++ &[_][]const u8{renamedKey(T, field.name)};
            }
        }
        return keys;
    }
}

/// Decode a `Value` into an instance of `T`.
///
/// Number policy: float targets accept `.integer` values (converted via
/// `@floatFromInt`), but integer targets do NOT accept `.float` values --
/// `1e2` parses as `.float` and stays one, so it never decodes into an
/// integer field. In typed mode, integer literals in the range
/// [minInt(i128), maxInt(i128)] parse as `.integer` and decode into any
/// integer target that fits (via overflow-checked cast). For u128 or values
/// beyond i128 range, use `number_mode = .raw` so the lexeme is preserved
/// and decoded directly into the target. JSON `null` decodes only into
/// optional targets; for any other target it errors like an absent field
/// (`error.MissingField`).
pub fn decode(comptime T: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions) DecodeError!T {
    var path: PathBuilder = .{ .buf = .empty };
    return decodeInner(T, arena, value, options, &path);
}

/// Parse + decode in one call. See `decode` for the decoding rules.
///
/// Fast path: types without `Value` fields, `fromJson` hooks, or tagged
/// unions decode in a single streaming pass with no intermediate `Value`
/// tree. On any error the input is re-decoded through the tree path, so
/// diagnostics and error selection are always the canonical ones. Callers
/// requesting `options.spans` use the tree path unconditionally.
pub fn parseInto(comptime T: type, arena: Allocator, src: []const u8, options: parser_mod.ParseOptions) (parser_mod.Error || DecodeError)!T {
    if (comptime needsTree(T)) return parseIntoTree(T, arena, src, options);
    if (options.spans != null) return parseIntoTree(T, arena, src, options);
    return streamParseInto(T, arena, src, options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => parseIntoTree(T, arena, src, options),
    };
}

fn parseIntoTree(comptime T: type, arena: Allocator, src: []const u8, options: parser_mod.ParseOptions) (parser_mod.Error || DecodeError)!T {
    const value = try parser_mod.parse(arena, src, options);
    return decode(T, arena, value, options);
}

/// Reader-input variant of `parseInto`: drains the reader into arena
/// memory, then decodes the slice (streaming when the type allows).
pub fn parseIntoReader(comptime T: type, arena: Allocator, reader: *std.Io.Reader, options: parser_mod.ParseOptions) (parser_mod.ReaderError || DecodeError)!T {
    const input = try reader.allocRemaining(arena, .unlimited);
    return parseInto(T, arena, input, options);
}

fn decodeInner(comptime T: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (T == Value) return value;

    // Custom fromJson hook short-circuit.
    if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "fromJson"))) {
        comptime {
            const fn_info = @typeInfo(@TypeOf(T.fromJson)).@"fn";
            if (fn_info.params.len != 3) {
                @compileError(@typeName(T) ++ ".fromJson must take exactly 3 params: (Allocator, Value, ParseOptions)");
            }
        }
        return T.fromJson(arena, value, options);
    }

    // JSON `null` satisfies optionals only (handled in decodeOptional). For
    // any other target the field is effectively absent, so the error matches
    // the missing-field case.
    if (comptime @typeInfo(T) != .optional) {
        if (value == .null) {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected {s}, got null", .{@typeName(T)});
                try appendDiag(list, arena, path, msg, null);
            }
            return error.MissingField;
        }
    }

    // Tagged-union dispatch.
    if (comptime (@typeInfo(T) == .@"union" and @hasDecl(T, "json_tag"))) {
        return decodeTaggedUnion(T, arena, value, options, path);
    }

    return switch (@typeInfo(T)) {
        .bool => decodeBool(value, arena, options, path),
        .int => decodeInt(T, value, arena, options, path),
        .float => decodeFloat(T, value, arena, options, path),
        .pointer => |p| decodePointer(T, p, arena, value, options, path),
        .array => |a| decodeArray(T, a, arena, value, options, path),
        .optional => |o| decodeOptional(o.child, arena, value, options, path),
        .@"struct" => |s| decodeStruct(T, s, arena, value, options, path),
        .@"enum" => decodeEnum(T, value, arena, options, path),
        else => @compileError("json decode: unsupported type " ++ @typeName(T)),
    };
}

fn decodeBool(value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!bool {
    if (value != .bool) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected boolean, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    return value.bool;
}

fn decodeInt(comptime T: type, value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    // Raw-mode lexeme: parse directly into T so wide targets (u64, i128,
    // u128) are not bottlenecked by an i128 intermediate. Float-syntax
    // lexemes fail parseInt (InvalidCharacter) and become TypeMismatch,
    // matching the typed-mode policy of never coercing floats to ints.
    switch (value) {
        .integer => |n| {
            if (std.math.cast(T, n)) |v| return v;
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "integer {d} out of range for {s}", .{ n, @typeName(T) });
                try appendDiag(list, arena, path, msg, null);
            }
            return error.Overflow;
        },
        .number_raw => |raw| {
            return std.fmt.parseInt(T, raw, 10) catch |err| {
                if (options.errors) |list| {
                    const msg = switch (err) {
                        error.Overflow => try std.fmt.allocPrint(arena, "integer {s} out of range for {s}", .{ raw, @typeName(T) }),
                        error.InvalidCharacter => try std.fmt.allocPrint(arena, "expected integer, got number {s}", .{raw}),
                    };
                    try appendDiag(list, arena, path, msg, null);
                }
                return switch (err) {
                    error.Overflow => error.Overflow,
                    error.InvalidCharacter => error.TypeMismatch,
                };
            };
        },
        else => {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected integer, got {s}", .{@tagName(value)});
                try appendDiag(list, arena, path, msg, null);
            }
            return error.TypeMismatch;
        },
    }
}

fn decodeFloat(comptime T: type, value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    return switch (value) {
        .float => |f| blk: {
            const result: T = @floatCast(f);
            // A finite f64 that overflows the narrower target is a caller error,
            // not a lossless cast. A genuine inf/nan source passes through.
            if (!std.math.isInf(f) and std.math.isInf(result)) return error.Overflow;
            break :blk result;
        },
        .integer => |n| blk: {
            const result: T = @floatFromInt(n);
            if (std.math.isInf(result)) return error.Overflow;
            break :blk result;
        },
        .number_raw => |raw| blk: {
            const f = std.fmt.parseFloat(f64, raw) catch {
                if (options.errors) |list| {
                    const msg = try std.fmt.allocPrint(arena, "expected float, got number {s}", .{raw});
                    try appendDiag(list, arena, path, msg, null);
                }
                return error.TypeMismatch;
            };
            const result: T = @floatCast(f);
            if (!std.math.isInf(f) and std.math.isInf(result)) return error.Overflow;
            break :blk result;
        },
        else => {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected float, got {s}", .{@tagName(value)});
                try appendDiag(list, arena, path, msg, null);
            }
            return error.TypeMismatch;
        },
    };
}

fn decodePointer(comptime T: type, comptime p: std.builtin.Type.Pointer, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (p.size != .slice) @compileError("json decode: only slice pointers supported, got " ++ @typeName(T));
    if (p.child == u8 and p.is_const) {
        if (value != .string) {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected string, got {s}", .{@tagName(value)});
                try appendDiag(list, arena, path, msg, null);
            }
            return error.TypeMismatch;
        }
        return value.string;
    }
    if (value != .array) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected array, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    const items = value.array;
    const out = try arena.alloc(p.child, items.len);
    for (items, 0..) |item, i| {
        const prev = try path.pushIndex(arena, i);
        defer path.restore(prev);
        out[i] = try decodeInner(p.child, arena, item, options, path);
    }
    return out;
}

fn decodeArray(comptime T: type, comptime a: std.builtin.Type.Array, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .array) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected array, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    if (value.array.len != a.len) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "array length mismatch: expected {d}, got {d}", .{ a.len, value.array.len });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    var out: T = undefined;
    // Zig rejects indexing an empty array even in unreachable loop bodies,
    // so skip the loop entirely for zero-length array types.
    if (comptime a.len > 0) {
        for (value.array, 0..) |item, i| {
            const prev = try path.pushIndex(arena, i);
            defer path.restore(prev);
            out[i] = try decodeInner(a.child, arena, item, options, path);
        }
    }
    return out;
}

fn decodeOptional(comptime Child: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!?Child {
    if (value == .null) return null;
    return try decodeInner(Child, arena, value, options, path);
}

fn decodeStruct(comptime T: type, comptime s: std.builtin.Type.Struct, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    comptime validateAnnotations(T);
    if (value != .object) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected object, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    const obj = value.object;

    // Unknown-field check runs before field assignment so that an
    // unrecognized key is reported as UnknownField rather than being
    // shadowed by a subsequent MissingField on a required field.
    if (!options.ignore_unknown_fields) {
        var it = obj.iterator();
        outer: while (it.next()) |entry| {
            inline for (comptime expectedKeys(T)) |expected| {
                if (std.mem.eql(u8, entry.key_ptr.*, expected)) continue :outer;
            }
            // Unknown key. Try a suggestion.
            const key = entry.key_ptr.*;
            const suggestion = lev.closestMatch(key, comptime expectedKeys(T), lev.suggestionThreshold(key.len));

            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "unknown field `{s}`", .{key});
                const suggestion_owned: ?[]const u8 = if (suggestion) |s_str| try arena.dupe(u8, s_str) else null;
                try appendDiag(list, arena, path, msg, suggestion_owned);
            }
            return error.UnknownField;
        }
    }

    var out: T = undefined;

    inline for (s.fields) |field| {
        if (comptime isSkipped(T, field.name)) {
            const dv = comptime field.defaultValue() orelse
                @compileError("json_skip field `" ++ field.name ++ "` on " ++ @typeName(T) ++ " has no default value");
            @field(out, field.name) = dv;
        } else if (comptime isFlattened(T, field.name)) {
            // Decode the inner struct from the SAME parent value (no key lookup).
            // The parent's expectedKeys already validated all keys, so suppress
            // unknown-field errors in the inner struct to avoid false positives
            // on sibling fields the inner type doesn't know about.
            const prev = try path.pushSegment(arena, field.name);
            defer path.restore(prev);
            var flat_opts = options;
            flat_opts.ignore_unknown_fields = true;
            @field(out, field.name) = try decodeInner(field.type, arena, value, flat_opts, path);
        } else {
            const eff_key = comptime renamedKey(T, field.name);
            if (obj.get(eff_key)) |fv| {
                const prev = try path.pushSegment(arena, eff_key);
                defer path.restore(prev);
                @field(out, field.name) = try decodeInner(field.type, arena, fv, options, path);
            } else if (field.defaultValue()) |dv| {
                @field(out, field.name) = dv;
            } else if (@typeInfo(field.type) == .optional) {
                @field(out, field.name) = null;
            } else {
                if (options.errors) |list| {
                    const msg = try std.fmt.allocPrint(arena, "missing required field `{s}`", .{eff_key});
                    try appendDiag(list, arena, path, msg, null);
                }
                return error.MissingField;
            }
        }
    }

    return out;
}

/// Effective (renamed) wire names of every variant of union `T`.
fn variantNames(comptime T: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (@typeInfo(T).@"union".fields) |field| {
            names = names ++ &[_][]const u8{renamedKey(T, field.name)};
        }
        return names;
    }
}

fn decodeTaggedUnion(comptime T: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    comptime validateAnnotations(T);
    if (value != .object) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected object for {s}, got {s}", .{ @typeName(T), @tagName(value) });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    const obj = value.object;
    const tag_field = T.json_tag;
    const tag_value = obj.get(tag_field) orelse {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "missing discriminator field `{s}` for {s}", .{ tag_field, @typeName(T) });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.MissingField;
    };
    if (tag_value != .string) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected string for discriminator `{s}`, got {s}", .{ tag_field, @tagName(tag_value) });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }

    inline for (@typeInfo(T).@"union".fields) |union_field| {
        const variant_name = union_field.name;
        const effective_name = comptime renamedKey(T, variant_name);
        if (std.mem.eql(u8, tag_value.string, effective_name)) {
            const PayloadType = union_field.type;

            if (PayloadType == void) {
                return @unionInit(T, variant_name, {});
            }

            // Build a filtered object view that drops the discriminator field.
            var filtered: value_mod.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, tag_field)) continue;
                const key_dup = try arena.dupe(u8, entry.key_ptr.*);
                try filtered.put(arena, key_dup, entry.value_ptr.*);
            }
            const filtered_value = Value{ .object = filtered };
            const payload = try decodeInner(PayloadType, arena, filtered_value, options, path);
            return @unionInit(T, variant_name, payload);
        }
    }
    if (options.errors) |list| {
        const tag = tag_value.string;
        const suggestion = lev.closestMatch(tag, comptime variantNames(T), lev.suggestionThreshold(tag.len));
        const msg = try std.fmt.allocPrint(arena, "unknown variant `{s}` for {s}", .{ tag, @typeName(T) });
        const suggestion_owned: ?[]const u8 = if (suggestion) |s_str| try arena.dupe(u8, s_str) else null;
        try appendDiag(list, arena, path, msg, suggestion_owned);
    }
    return error.InvalidEnumValue;
}

fn decodeEnum(comptime T: type, value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    switch (value) {
        .string => |s| {
            if (std.meta.stringToEnum(T, s)) |v| return v;
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "invalid enum value `{s}` for {s}", .{ s, @typeName(T) });
                try appendDiag(list, arena, path, msg, null);
            }
            return error.InvalidEnumValue;
        },
        .integer => |n| {
            if (std.enums.fromInt(T, n)) |v| return v;
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "integer {d} is not a valid value of {s}", .{ n, @typeName(T) });
                try appendDiag(list, arena, path, msg, null);
            }
            return error.InvalidEnumValue;
        },
        else => {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected string or integer for enum {s}, got {s}", .{ @typeName(T), @tagName(value) });
                try appendDiag(list, arena, path, msg, null);
            }
            return error.TypeMismatch;
        },
    }
}

// Streaming typed decode (no Value tree)

const tokenizer_mod = @import("tokenizer.zig");
const RawToken = tokenizer_mod.RawToken;

/// Comptime: true when decoding `T` requires a materialized `Value` (or a
/// whole-object view) somewhere in its type closure: `Value` targets,
/// `fromJson` hooks, unions (the `json_tag` discriminator may follow the
/// payload), flattened non-struct fields, and effective-key collisions
/// between a struct and its flattened fields. Those decode through the
/// tree path; everything else streams token-to-field.
fn needsTree(comptime T: type) bool {
    return comptime needsTreeImpl(T, &.{});
}

fn needsTreeImpl(comptime T: type, comptime seen: []const type) bool {
    comptime {
        for (seen) |S| if (S == T) return false;
        if (T == Value) return true;
        const seen2 = seen ++ &[_]type{T};
        return switch (@typeInfo(T)) {
            .@"struct" => |s| blk: {
                if (@hasDecl(T, "fromJson")) break :blk true;
                for (s.fields) |f| {
                    if (isFlattened(T, f.name) and @typeInfo(f.type) != .@"struct") break :blk true;
                }
                if (hasKeyCollisions(T)) break :blk true;
                for (s.fields) |f| {
                    if (needsTreeImpl(f.type, seen2)) break :blk true;
                }
                break :blk false;
            },
            .@"union" => true,
            .pointer => |p| p.size == .slice and !(p.child == u8 and p.is_const) and needsTreeImpl(p.child, seen2),
            .array => |a| needsTreeImpl(a.child, seen2),
            .optional => |o| needsTreeImpl(o.child, seen2),
            else => false,
        };
    }
}

/// One streamable destination: the effective wire key, the field path
/// from the outer struct (flattened fields contribute nested paths),
/// and the leaf type.
const EffField = struct {
    key: []const u8,
    path: []const []const u8,
    Type: type,
};

/// Effective field list of `T` with flattened inner structs expanded,
/// skipped fields excluded. Mirrors `expectedKeys` exactly.
fn effFieldsOf(comptime T: type, comptime prefix: []const []const u8) []const EffField {
    comptime {
        var out: []const EffField = &.{};
        for (@typeInfo(T).@"struct".fields) |f| {
            if (isSkipped(T, f.name)) continue;
            const p2 = prefix ++ &[_][]const u8{f.name};
            if (isFlattened(T, f.name)) {
                out = out ++ effFieldsOf(f.type, p2);
            } else {
                out = out ++ &[_]EffField{.{ .key = renamedKey(T, f.name), .path = p2, .Type = f.type }};
            }
        }
        return out;
    }
}

/// Two effective fields sharing one wire key (an outer field colliding
/// with a flattened inner one). The tree path decodes such a key into
/// every destination; a single token stream cannot, so collide -> tree.
fn hasKeyCollisions(comptime T: type) bool {
    comptime {
        const fs = effFieldsOf(T, &.{});
        for (fs, 0..) |a, i| {
            for (fs[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.key, b.key)) return true;
            }
        }
        return false;
    }
}

fn PathType(comptime T: type, comptime path: []const []const u8) type {
    comptime {
        var C = T;
        for (path) |seg| C = @FieldType(C, seg);
        return C;
    }
}

fn pathPtr(comptime T: type, comptime path: []const []const u8, base: *T) *PathType(T, path) {
    if (comptime path.len == 0) return base;
    return pathPtr(@FieldType(T, path[0]), path[1..], &@field(base.*, path[0]));
}

/// Assign defaults to every `json_skip` field of `T`, recursing through
/// flattened inner structs. Mirrors the skip branch of `decodeStruct`.
fn assignSkippedDefaults(comptime T: type, comptime prefix: []const []const u8, comptime Outer: type, out: *Outer) void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime isSkipped(T, f.name)) {
            const dv = comptime f.defaultValue() orelse
                @compileError("json_skip field `" ++ f.name ++ "` on " ++ @typeName(T) ++ " has no default value");
            pathPtr(Outer, prefix ++ &[_][]const u8{f.name}, out).* = dv;
        } else if (comptime isFlattened(T, f.name)) {
            assignSkippedDefaults(f.type, prefix ++ &[_][]const u8{f.name}, Outer, out);
        }
    }
}

/// Streaming `parseInto`: one tokenizer pass decoding directly into `T`.
/// Success semantics match parse-then-decode exactly (same tokenizer,
/// same scalar decoders, same skip validation via `parseValue`); every
/// error abandons the pass and the caller reruns the tree path, whose
/// error selection and diagnostics are canonical.
fn streamParseInto(comptime T: type, arena: Allocator, src: []const u8, options: parser_mod.ParseOptions) (parser_mod.Error || DecodeError)!T {
    var stream_options = options;
    stream_options.errors = null;
    stream_options.spans = null;
    var p = parser_mod.Parser{
        .arena = arena,
        .input = src,
        .tokenizer = .init(src, options.dialect),
        .options = stream_options,
    };
    const t = (try p.next()) orelse return error.JsonParseError;
    const out = try streamValue(T, &p, t, 0);
    if (try p.next()) |_| return error.JsonParseError;
    return out;
}

fn streamValue(comptime T: type, p: *parser_mod.Parser, t: RawToken, depth: usize) (parser_mod.Error || DecodeError)!T {
    const info = @typeInfo(T);
    if (comptime info == .optional) {
        if (t.kind == .literal_null) return null;
        return try streamValue(info.optional.child, p, t, depth);
    }
    // JSON null into a non-optional mirrors decodeInner's policy.
    if (t.kind == .literal_null) return error.MissingField;

    // Scalars reuse the tree path's decoders on a scalar Value built by
    // the parser's own primitives, so numeric and enum semantics stay
    // single-sourced. Diagnostics are off (errors == null), so the
    // throwaway path builder never allocates.
    var path: PathBuilder = .{ .buf = .empty };
    return switch (comptime @typeInfo(T)) {
        .bool => switch (t.kind) {
            .literal_true => true,
            .literal_false => false,
            else => error.TypeMismatch,
        },
        .int => switch (t.kind) {
            .number => try decodeInt(T, try p.parseNumber(t), p.arena, p.options, &path),
            else => error.TypeMismatch,
        },
        .float => switch (t.kind) {
            .number => try decodeFloat(T, try p.parseNumber(t), p.arena, p.options, &path),
            else => error.TypeMismatch,
        },
        .@"enum" => switch (t.kind) {
            .string => try decodeEnum(T, .{ .string = try p.decodeString(t) }, p.arena, p.options, &path),
            .number => try decodeEnum(T, try p.parseNumber(t), p.arena, p.options, &path),
            else => error.TypeMismatch,
        },
        .pointer => |ptr| try streamPointer(T, ptr, p, t, depth),
        .array => |arr| try streamFixedArray(T, arr, p, t, depth),
        .@"struct" => try streamStruct(T, p, t, depth),
        else => @compileError("json decode: unsupported type " ++ @typeName(T)),
    };
}

fn streamPointer(comptime T: type, comptime ptr: std.builtin.Type.Pointer, p: *parser_mod.Parser, t: RawToken, depth: usize) (parser_mod.Error || DecodeError)!T {
    if (comptime ptr.size != .slice) @compileError("json decode: only slice pointers supported, got " ++ @typeName(T));
    if (comptime (ptr.child == u8 and ptr.is_const)) {
        if (t.kind != .string) return error.TypeMismatch;
        return try p.decodeString(t);
    }
    if (t.kind != .array_begin) return error.TypeMismatch;
    if (depth >= p.depthLimit()) return error.NestingTooDeep;
    var items: std.ArrayList(ptr.child) = .empty;
    var at_first = true;
    while (true) {
        const et = (try p.next()) orelse return error.JsonParseError;
        if (et.kind == .array_end) {
            if (at_first or p.options.dialect == .jsonc) break;
            return error.JsonParseError;
        }
        at_first = false;
        try items.append(p.arena, try streamValue(ptr.child, p, et, depth + 1));
        const sep = (try p.next()) orelse return error.JsonParseError;
        if (sep.kind == .array_end) break;
        if (sep.kind != .comma) return error.JsonParseError;
    }
    return items.toOwnedSlice(p.arena);
}

fn streamFixedArray(comptime T: type, comptime arr: std.builtin.Type.Array, p: *parser_mod.Parser, t: RawToken, depth: usize) (parser_mod.Error || DecodeError)!T {
    if (t.kind != .array_begin) return error.TypeMismatch;
    if (depth >= p.depthLimit()) return error.NestingTooDeep;
    var out: T = undefined;
    var i: usize = 0;
    var at_first = true;
    while (true) {
        const et = (try p.next()) orelse return error.JsonParseError;
        if (et.kind == .array_end) {
            if (at_first or p.options.dialect == .jsonc) break;
            return error.JsonParseError;
        }
        at_first = false;
        if (comptime arr.len == 0) return error.TypeMismatch;
        if (i >= arr.len) return error.TypeMismatch;
        out[i] = try streamValue(arr.child, p, et, depth + 1);
        i += 1;
        const sep = (try p.next()) orelse return error.JsonParseError;
        if (sep.kind == .array_end) break;
        if (sep.kind != .comma) return error.JsonParseError;
    }
    if (i != arr.len) return error.TypeMismatch;
    return out;
}

fn streamStruct(comptime T: type, p: *parser_mod.Parser, t: RawToken, depth: usize) (parser_mod.Error || DecodeError)!T {
    comptime validateAnnotations(T);
    if (t.kind != .object_begin) return error.TypeMismatch;
    if (depth >= p.depthLimit()) return error.NestingTooDeep;

    const eff = comptime effFieldsOf(T, &.{});
    var seen = [_]bool{false} ** eff.len;
    var out: T = undefined;
    assignSkippedDefaults(T, &.{}, T, &out);

    var at_first = true;
    while (true) {
        const kt = (try p.next()) orelse return error.JsonParseError;
        if (kt.kind == .object_end) {
            if (at_first or p.options.dialect == .jsonc) break;
            return error.JsonParseError;
        }
        at_first = false;
        if (kt.kind != .string) return error.JsonParseError;
        const key = try p.decodeString(kt);
        const ct = (try p.next()) orelse return error.JsonParseError;
        if (ct.kind != .colon) return error.JsonParseError;
        const vt = (try p.next()) orelse return error.JsonParseError;

        var matched = false;
        inline for (eff, 0..) |f, idx| {
            if (!matched and std.mem.eql(u8, key, f.key)) {
                // Duplicate keys re-decode and overwrite: last wins,
                // matching the tree parser's object semantics.
                pathPtr(T, f.path, &out).* = try streamValue(f.Type, p, vt, depth + 1);
                seen[idx] = true;
                matched = true;
            }
        }
        if (!matched) {
            if (!p.options.ignore_unknown_fields) return error.UnknownField;
            // Structural skip with identical validation and depth limits;
            // the discarded Value is arena garbage, same as the tree path.
            _ = try p.parseValue(vt, depth + 1);
        }

        const sep = (try p.next()) orelse return error.JsonParseError;
        if (sep.kind == .object_end) break;
        if (sep.kind != .comma) return error.JsonParseError;
    }

    inline for (eff, 0..) |f, idx| {
        if (!seen[idx]) {
            const Parent = PathType(T, f.path[0 .. f.path.len - 1]);
            const fi = comptime blk: {
                for (@typeInfo(Parent).@"struct".fields) |sf| {
                    if (std.mem.eql(u8, sf.name, f.path[f.path.len - 1])) break :blk sf;
                }
                unreachable;
            };
            const dv_opt = comptime fi.defaultValue();
            if (dv_opt) |dv| {
                pathPtr(T, f.path, &out).* = dv;
            } else if (comptime @typeInfo(f.Type) == .optional) {
                pathPtr(T, f.path, &out).* = null;
            } else {
                return error.MissingField;
            }
        }
    }
    return out;
}

const parse = @import("parser.zig").parse;

test "decode struct with defaults optionals slices enums" {
    const Config = struct {
        title: []const u8,
        port: u16 = 8080,
        nick: ?[]const u8,
        ratio: f64,
        tags: []const []const u8,
        mode: enum { fast, slow },
        server: struct { host: []const u8, tls: bool = false },
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const cfg = try parseInto(Config, ar.allocator(),
        \\{"title":"t","nick":null,"ratio":1.5,"tags":["a"],"mode":"fast",
        \\ "server":{"host":"h"}}
    , .{});
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.nick);
    try std.testing.expectEqual(@as(f64, 1.5), cfg.ratio);
    try std.testing.expectEqual(false, cfg.server.tls);
}

test "unknown field errors with did-you-mean; opt-out flag" {
    const C = struct { port: u16 = 1 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(error.UnknownField, parseInto(C, a, "{\"prot\":2}", .{}));
    const c = try parseInto(C, a, "{\"prot\":2}", .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(u16, 1), c.port);
}

test "int overflow checked" {
    const C = struct { n: u8 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectError(error.Overflow, parseInto(C, ar.allocator(), "{\"n\":256}", .{}));
}

test "json_rename json_skip json_flatten" {
    const C = struct {
        pub const json_rename = .{ .listen_addr = "listen-addr" };
        pub const json_skip = .{"runtime"};
        pub const json_flatten = .{"common"};
        listen_addr: []const u8,
        runtime: u32 = 7,
        common: struct { verbose: bool = false },
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(),
        "{\"listen-addr\":\"x\",\"verbose\":true}", .{});
    try std.testing.expectEqualStrings("x", c.listen_addr);
    try std.testing.expectEqual(@as(u32, 7), c.runtime);
    try std.testing.expectEqual(true, c.common.verbose);
}

test "json_tag tagged union" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        http: struct { port: u16 },
        exec: struct { cmd: []const u8 },
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const p_ = try parseInto(Plugin, ar.allocator(), "{\"kind\":\"http\",\"port\":80}", .{});
    try std.testing.expectEqual(@as(u16, 80), p_.http.port);
}

test "parseIntoReader decodes from a reader" {
    const C = struct { port: u16 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var r: std.Io.Reader = .fixed("{\"port\":8080}");
    const c = try parseIntoReader(C, ar.allocator(), &r, .{});
    try testing.expectEqual(@as(u16, 8080), c.port);
}

test "decode null into non-optional field is MissingField" {
    const C = struct { n: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.MissingField, parseInto(C, ar.allocator(), "{\"n\":null}", .{}));
}

test "decode null/optional matrix" {
    const C = struct {
        a: ?u32, // present as null
        b: ?u32, // absent
        c: ?u32, // present with value
        d: u32 = 5, // absent, has default
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "{\"a\":null,\"c\":3}", .{});
    try testing.expectEqual(@as(?u32, null), c.a);
    try testing.expectEqual(@as(?u32, null), c.b);
    try testing.expectEqual(@as(?u32, 3), c.c);
    try testing.expectEqual(@as(u32, 5), c.d);
}

test "decode float field accepts integer value" {
    const C = struct { x: f32, y: f64 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "{\"x\":3,\"y\":-7}", .{});
    try testing.expectEqual(@as(f32, 3.0), c.x);
    try testing.expectEqual(@as(f64, -7.0), c.y);
}

test "decode int field rejects float value" {
    const C = struct { n: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.TypeMismatch, parseInto(C, a, "{\"n\":1.5}", .{}));
    // 1e2 lexes as .float and stays one; it never decodes into an int.
    try testing.expectError(error.TypeMismatch, parseInto(C, a, "{\"n\":1e2}", .{}));
}

test "decode int and float fields in raw number mode" {
    const C = struct { n: u32, x: f64, big: i64 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c = try parseInto(C, a, "{\"n\":42,\"x\":1.5,\"big\":9000000000}", .{ .number_mode = .raw });
    try testing.expectEqual(@as(u32, 42), c.n);
    try testing.expectEqual(@as(f64, 1.5), c.x);
    try testing.expectEqual(@as(i64, 9000000000), c.big);

    // Raw mode keeps typed-mode's policy: a float lexeme is not an int,
    // and an out-of-range integer lexeme overflows.
    const D = struct { n: u32 };
    try testing.expectError(error.TypeMismatch, parseInto(D, a, "{\"n\":1.5}", .{ .number_mode = .raw }));
    try testing.expectError(error.TypeMismatch, parseInto(D, a, "{\"n\":1e2}", .{ .number_mode = .raw }));
    try testing.expectError(error.Overflow, parseInto(D, a, "{\"n\":99999999999}", .{ .number_mode = .raw }));
}

test "decode enum from integer tag" {
    const Level = enum(u8) { debug = 0, info = 1, warn = 2, err = 3 };
    const C = struct { level: Level };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "{\"level\":2}", .{});
    try testing.expectEqual(Level.warn, c.level);
}

test "decode enum from out-of-range integer is error" {
    const Level = enum(u8) { debug = 0, info = 1 };
    const C = struct { level: Level };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.InvalidEnumValue, parseInto(C, ar.allocator(), "{\"level\":99}", .{}));
}

test "decode enum from invalid string is error" {
    const C = struct { mode: enum { fast, slow } };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.InvalidEnumValue, parseInto(C, ar.allocator(), "{\"mode\":\"warp\"}", .{}));
}

test "decode missing required field is error" {
    const C = struct { required: []const u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.MissingField, parseInto(C, ar.allocator(), "{}", .{}));
}

test "decode fixed-size array and length mismatch" {
    const C = struct { rgb: [3]u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c = try parseInto(C, a, "{\"rgb\":[1,2,3]}", .{});
    try testing.expectEqual(@as(u8, 1), c.rgb[0]);
    try testing.expectEqual(@as(u8, 3), c.rgb[2]);
    try testing.expectError(error.TypeMismatch, parseInto(C, a, "{\"rgb\":[1,2]}", .{}));
}

test "decode nested struct three levels deep" {
    const C = struct {
        a: struct {
            b: struct {
                c: struct { n: u32 },
            },
        },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "{\"a\":{\"b\":{\"c\":{\"n\":42}}}}", .{});
    try testing.expectEqual(@as(u32, 42), c.a.b.c.n);
}

test "decode slice of structs" {
    const User = struct { name: []const u8, age: u32 };
    const C = struct { users: []const User };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(),
        "{\"users\":[{\"name\":\"alice\",\"age\":30},{\"name\":\"bob\",\"age\":25}]}", .{});
    try testing.expectEqual(@as(usize, 2), c.users.len);
    try testing.expectEqualStrings("alice", c.users[0].name);
    try testing.expectEqual(@as(u32, 25), c.users[1].age);
}

test "decode embedded Value field keeps dynamic subtree" {
    const C = struct { meta: Value, n: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "{\"meta\":{\"a\":[1,2]},\"n\":5}", .{});
    try testing.expectEqual(@as(u32, 5), c.n);
    try testing.expect(c.meta == .object);
    try testing.expectEqual(@as(i64, 2), c.meta.getT(i64, "a[1]").?);
}

test "decode raw Value passthrough at any variant" {
    const C = struct { anything: Value };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c = try parseInto(C, a, "{\"anything\":\"goes\"}", .{});
    try testing.expectEqualStrings("goes", c.anything.string);
    // `null` is a Value variant, so it passes through rather than erroring.
    const c2 = try parseInto(C, a, "{\"anything\":null}", .{});
    try testing.expect(c2.anything == .null);
}

test "decode: fromJson hook short-circuits built-in dispatch" {
    const SemVer = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn fromJson(arena: std.mem.Allocator, value: Value, _: parser_mod.ParseOptions) DecodeError!@This() {
            _ = arena;
            if (value != .string) return error.TypeMismatch;
            var it = std.mem.tokenizeAny(u8, value.string, ".");
            const maj_s = it.next() orelse return error.TypeMismatch;
            const min_s = it.next() orelse return error.TypeMismatch;
            const pat_s = it.next() orelse return error.TypeMismatch;
            const maj = std.fmt.parseInt(u32, maj_s, 10) catch return error.TypeMismatch;
            const min = std.fmt.parseInt(u32, min_s, 10) catch return error.TypeMismatch;
            const pat = std.fmt.parseInt(u32, pat_s, 10) catch return error.TypeMismatch;
            return .{ .major = maj, .minor = min, .patch = pat };
        }
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const C = struct { v: SemVer };
    const c = try parseInto(C, ar.allocator(), "{\"v\":\"1.2.3\"}", .{});
    try testing.expectEqual(@as(u32, 1), c.v.major);
    try testing.expectEqual(@as(u32, 2), c.v.minor);
    try testing.expectEqual(@as(u32, 3), c.v.patch);
}

test "decode: json_rename unknown-field check uses renamed name" {
    const C = struct {
        pub const json_rename = .{ .listen_addr = "listen-addr" };
        listen_addr: []const u8,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    // Original snake_case key -- should error since renamed key is expected.
    try testing.expectError(error.UnknownField, parseInto(C, ar.allocator(), "{\"listen_addr\":\"0.0.0.0\"}", .{}));
}

test "decode: json_skip rejects skipped key in strict mode" {
    const C = struct {
        pub const json_skip = .{"internal"};
        name: []const u8,
        internal: u32 = 7,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    // Skipped fields are excluded from the expected-keys set,
    // so a JSON key matching a skipped field is "unknown".
    try testing.expectError(error.UnknownField, parseInto(C, ar.allocator(), "{\"name\":\"foo\",\"internal\":99}", .{}));
}

test "decode: json_flatten inner json_rename expands into expected keys" {
    const Inner = struct {
        pub const json_rename = .{ .log_level = "log-level" };
        log_level: []const u8 = "info",
    };
    const Outer = struct {
        pub const json_rename = .{ .listen_addr = "listen-addr" };
        pub const json_flatten = .{"inner"};
        listen_addr: []const u8,
        inner: Inner,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(Outer, ar.allocator(),
        "{\"listen-addr\":\"x\",\"log-level\":\"debug\"}", .{});
    try testing.expectEqualStrings("x", c.listen_addr);
    try testing.expectEqualStrings("debug", c.inner.log_level);
}

test "decode: json_flatten unknown-field check expands flattened keys" {
    const Inner = struct { x: u32 };
    const Outer = struct {
        pub const json_flatten = .{"inner"};
        name: []const u8,
        inner: Inner,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.UnknownField, parseInto(Outer, ar.allocator(),
        "{\"name\":\"foo\",\"x\":42,\"unexpected\":true}", .{}));
}

test "decode: tagged union missing discriminator -> MissingField" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        http: struct { host: []const u8 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.MissingField, parseInto(Plugin, ar.allocator(), "{\"host\":\"localhost\"}", .{}));
}

test "decode: tagged union unknown discriminator -> InvalidEnumValue" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        http: struct { host: []const u8 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.InvalidEnumValue, parseInto(Plugin, ar.allocator(),
        "{\"kind\":\"xyz\",\"host\":\"localhost\"}", .{}));
}

test "decode: tagged union unknown variant diagnostic suggests closest match" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        http: struct { port: u16 = 0 },
        exec: struct { cmd: []const u8 = "" },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
    defer errs.deinit(a);

    _ = parseInto(Plugin, a, "{\"kind\":\"htpp\"}", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "unknown variant `htpp`") != null);
    try testing.expectEqualStrings("http", errs.items[0].suggestion.?);
}

test "decode: tagged union missing discriminator diagnostic names tag field" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        http: struct { port: u16 = 0 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
    defer errs.deinit(a);

    _ = parseInto(Plugin, a, "{\"port\":80}", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "missing discriminator field `kind`") != null);
}

test "decode: missing-field diagnostic reports the JSON wire key" {
    const C = struct {
        pub const json_rename = .{ .listen_addr = "listen-addr" };
        listen_addr: []const u8,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
    defer errs.deinit(a);

    _ = parseInto(C, a, "{}", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "`listen-addr`") != null);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "listen_addr") == null);
}

test "decode: tagged union void variant" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        none,
        http: struct { port: u16 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const p_ = try parseInto(Plugin, ar.allocator(), "{\"kind\":\"none\"}", .{});
    try testing.expect(p_ == .none);
}

// A union without `json_tag` has no JSON shape to dispatch on, so it is
// rejected at compile time ("json decode: unsupported type"). Not
// runtime-testable; this mirrors the reference behavior.

test "decode: unknown field suggests closest match" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
    defer errs.deinit(a);

    // `prt` is a typo for `port`; `port` is also present so the required
    // field is satisfied and the unknown-field check runs.
    const C = struct { port: u16 };
    _ = parseInto(C, a, "{\"port\":8080,\"prt\":9090}", .{ .errors = &errs }) catch {};

    try testing.expect(errs.items.len == 1);
    try testing.expect(errs.items[0].suggestion != null);
    try testing.expectEqualStrings("port", errs.items[0].suggestion.?);
}

test "decode: nested type mismatch reports dotted path in message" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
    defer errs.deinit(a);

    const C = struct {
        server: struct { port: u16 },
    };
    _ = parseInto(C, a, "{\"server\":{\"port\":\"8080\"}}", .{ .errors = &errs }) catch {};

    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "server.port") != null);
}

test "PathBuilder: push/restore symmetry" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var path: PathBuilder = .{ .buf = .empty };

    const p1 = try path.pushSegment(arena.allocator(), "server");
    try testing.expectEqualStrings("server", path.slice());

    const p2 = try path.pushSegment(arena.allocator(), "port");
    try testing.expectEqualStrings("server.port", path.slice());

    path.restore(p2);
    try testing.expectEqualStrings("server", path.slice());

    const p3 = try path.pushIndex(arena.allocator(), 7);
    try testing.expectEqualStrings("server[7]", path.slice());

    path.restore(p3);
    path.restore(p1);
    try testing.expectEqualStrings("", path.slice());
}

test "decode operates on an already-parsed Value" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "{\"title\":\"json\",\"port\":8080,\"enabled\":true}", .{});
    const Config = struct {
        title: []const u8,
        port: u16,
        enabled: bool,
    };
    const cfg = try decode(Config, a, v, .{});
    try testing.expectEqualStrings("json", cfg.title);
    try testing.expectEqual(@as(u16, 8080), cfg.port);
    try testing.expectEqual(true, cfg.enabled);
}

test "wide-int round-trip: u64 max via encodeTyped -> parseInto" {
    // encodeTyped emits u64 at full width; parseInto must recover it.
    const S = struct { n: u64 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const encoder_mod = @import("encoder.zig");
    const orig: S = .{ .n = std.math.maxInt(u64) };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try encoder_mod.encodeTyped(&aw.writer, orig, a, .{});
    // "18446744073709551615" must appear verbatim in the encoded output.
    try testing.expect(std.mem.indexOf(u8, aw.written(), "18446744073709551615") != null);
    const back = try parseInto(S, a, aw.written(), .{});
    try testing.expectEqual(std.math.maxInt(u64), back.n);
}

test "wide-int round-trip: i128 extremes via number_mode=.raw" {
    const S = struct { n: i128 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const back_max = try parseInto(S, a, "{\"n\":170141183460469231731687303715884105727}", .{ .number_mode = .raw });
    try testing.expectEqual(std.math.maxInt(i128), back_max.n);
    const back_min = try parseInto(S, a, "{\"n\":-170141183460469231731687303715884105728}", .{ .number_mode = .raw });
    try testing.expectEqual(std.math.minInt(i128), back_min.n);
}

test "wide-int round-trip: u128 max via number_mode=.raw" {
    const S = struct { n: u128 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const back = try parseInto(S, a, "{\"n\":340282366920938463463374607431768211455}", .{ .number_mode = .raw });
    try testing.expectEqual(std.math.maxInt(u128), back.n);
}

test "wide-int: value in (i64max, u64max] parses as .integer, getT(u64) returns it" {
    // Values above i64 max but within u64 must NOT fall back to .float in typed mode.
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "18446744073709551615", .{});
    try testing.expect(v == .integer);
    const as_u64 = v.getT(u64, "").?;
    try testing.expectEqual(std.math.maxInt(u64), as_u64);
}

test "wide-int control: i64 min and small int still work" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const S = struct { a: i64, b: i32 };
    const c = try parseInto(S, a, "{\"a\":-9223372036854775808,\"b\":7}", .{});
    try testing.expectEqual(std.math.minInt(i64), c.a);
    try testing.expectEqual(@as(i32, 7), c.b);
}

test "decode float narrowing overflow is Overflow" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const C32 = struct { x: f32 };
    // 1e40 is finite as f64 but overflows f32 (~3.4e38 max).
    try testing.expectError(error.Overflow, parseInto(C32, a, "{\"x\":1e40}", .{}));
    // 3.5e38 is a float literal (stored as .float) that overflows f32.
    try testing.expectError(error.Overflow, parseInto(C32, a, "{\"x\":3.5e38}", .{}));
    // 3.0e38 is within f32 range -- must succeed.
    const c = try parseInto(C32, a, "{\"x\":3.0e38}", .{});
    try testing.expect(!std.math.isInf(c.x));

    // Integer 66000 overflows f16 (max 65504) via @floatFromInt.
    const C16 = struct { x: f16 };
    try testing.expectError(error.Overflow, parseInto(C16, a, "{\"x\":66000}", .{}));

    // f64 target with 1e40 -- no narrowing, finite result passes through.
    const C64 = struct { x: f64 };
    const c64 = try parseInto(C64, a, "{\"x\":1e40}", .{});
    try testing.expect(!std.math.isInf(c64.x));
}

test "decode zero-length fixed array field compiles and decodes" {
    const C = struct { xs: [0]u8, name: []const u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Empty JSON array for [0]u8 field must compile and decode successfully.
    const c = try parseInto(C, a, "{\"xs\":[],\"name\":\"ok\"}", .{});
    try testing.expectEqual([0]u8{}, c.xs);
    try testing.expectEqualStrings("ok", c.name);
    // Non-empty JSON array for [0]u8 field must be TypeMismatch (length mismatch).
    try testing.expectError(error.TypeMismatch, parseInto(C, a, "{\"xs\":[1],\"name\":\"ok\"}", .{}));
}

test "wide-int Document.set u64 max succeeds; u128 above i128 max returns error" {
    const document_mod = @import("document.zig");
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try document_mod.Document.parse(a, "{\"x\":0}", .{});
    // Setting a u64 max value must not panic.
    try doc.set("x", @as(u64, std.math.maxInt(u64)));
    try testing.expectEqual(std.math.maxInt(u64), doc.getT(u64, "x").?);
    // u128 above i128 max is unrepresentable as .integer and must error.
    try testing.expectError(error.InvalidValue, doc.set("x", @as(u128, std.math.maxInt(u128))));
}

// Streaming typed decode

/// Allocator wrapper that counts bytes handed out. Used to bound the
/// allocation cost of the streaming typed decode path.
const CountingAllocator = struct {
    child: Allocator,
    total: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.total += len;
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.total += new_len - memory.len;
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.total += new_len - memory.len;
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

test "parseInto streams: allocation bounded, no Value tree materialized" {
    // An array of structs large enough that tree materialization (a Value
    // box plus an ObjectMap per element) dwarfs the decoded output. The
    // streaming path must stay within a small multiple of the input size;
    // the tree path exceeds it several times over.
    const Rec = struct {
        id: u64,
        name: []const u8,
        active: bool,
        score: f64,
        tags: []const []const u8,
    };

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.append(testing.allocator, '[');
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        if (i != 0) try src.append(testing.allocator, ',');
        var buf: [160]u8 = undefined;
        const rec = try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"name\":\"record-{d}\",\"active\":{},\"score\":{d}.5,\"tags\":[\"a\",\"b\"]}}", .{ i, i, i % 2 == 0, i % 100 });
        try src.appendSlice(testing.allocator, rec);
    }
    try src.append(testing.allocator, ']');

    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var counting: CountingAllocator = .{ .child = ar.allocator() };

    const out = try parseInto([]const Rec, counting.allocator(), src.items, .{});
    try testing.expectEqual(@as(usize, 2000), out.len);
    try testing.expectEqualStrings("record-1999", out[1999].name);

    var tree_arena = ArenaAllocator.init(testing.allocator);
    defer tree_arena.deinit();
    var tree_counting: CountingAllocator = .{ .child = tree_arena.allocator() };
    const tree_out = try parseIntoTree([]const Rec, tree_counting.allocator(), src.items, .{});
    try testing.expectEqual(@as(usize, 2000), tree_out.len);

    // The streaming path allocates the decoded output plus list-growth
    // copies (measured ~6x input for this shape; the growth copies and
    // arena slack, not any tree). The tree path materializes a Value box
    // and an ObjectMap per element on top (measured ~26x). Bound the
    // streaming path well under the tree cost so a regression to tree
    // materialization fails loudly.
    try testing.expect(counting.total <= src.items.len * 8);
    try testing.expect(counting.total * 3 <= tree_counting.total);
}

test "streaming equivalence: duplicate key with invalid first occurrence decodes last-wins" {
    // The tree parser resolves duplicates before decode (last wins), so a
    // type-invalid FIRST occurrence must not fail parseInto: the streaming
    // pass errors, falls back to the tree, and succeeds.
    const T = struct { a: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const v = try parseInto(T, ar.allocator(), "{\"a\":\"not an int\",\"a\":7}", .{});
    try testing.expectEqual(@as(u32, 7), v.a);
}

test "streaming equivalence: unknown field wins over earlier type error" {
    // decodeStruct checks unknown keys over the whole object before any
    // field decode, so UnknownField must surface even when an earlier
    // field value would TypeMismatch.
    const T = struct { a: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.UnknownField, parseInto(T, ar.allocator(), "{\"a\":\"bad\",\"zzz\":1}", .{}));
}

test "streaming: jsonc comments and trailing commas decode typed" {
    const T = struct { a: u32, tags: []const []const u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const v = try parseInto(T, ar.allocator(),
        \\{
        \\  // comment
        \\  "a": 3,
        \\  "tags": ["x", "y",],
        \\}
    , .{ .dialect = .jsonc });
    try testing.expectEqual(@as(u32, 3), v.a);
    try testing.expectEqual(@as(usize, 2), v.tags.len);
}

test "streaming: escaped object key matches field" {
    const T = struct { name: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const v = try parseInto(T, ar.allocator(), "{\"na\\u006de\":5}", .{});
    try testing.expectEqual(@as(u32, 5), v.name);
}

test "streaming: deep nesting inside ignored unknown field is depth-bounded" {
    const T = struct { a: u32 = 0 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "{\"junk\":");
    try src.appendNTimes(testing.allocator, '[', 200);
    try src.appendNTimes(testing.allocator, ']', 200);
    try src.appendSlice(testing.allocator, "}");
    try testing.expectError(error.NestingTooDeep, parseInto(T, ar.allocator(), src.items, .{ .ignore_unknown_fields = true }));
}

test "streaming: u128 beyond i128 range errors typed, decodes raw" {
    const T = struct { n: u128 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const big = "{\"n\":200000000000000000000000000000000000000}";
    // Typed mode: the tree stores integers as i128 (overflow falls back to
    // float), so the streaming pass must not sneak a wider direct parse in.
    try testing.expectError(error.TypeMismatch, parseInto(T, ar.allocator(), big, .{}));
    // Raw mode: the verbatim lexeme decodes straight into u128, both paths.
    const v = try parseInto(T, ar.allocator(), big, .{ .number_mode = .raw });
    try testing.expectEqual(@as(u128, 200000000000000000000000000000000000000), v.n);
}

test "streaming: flatten inside flatten decodes from one object" {
    const Innermost = struct { z: u32 };
    const Inner = struct {
        y: u32,
        deep: Innermost,
        pub const json_flatten = .{"deep"};
    };
    const T = struct {
        x: u32,
        flat: Inner,
        skipped: u8 = 42,
        pub const json_flatten = .{"flat"};
        pub const json_skip = .{"skipped"};
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const v = try parseInto(T, ar.allocator(), "{\"x\":1,\"y\":2,\"z\":3}", .{});
    try testing.expectEqual(@as(u32, 1), v.x);
    try testing.expectEqual(@as(u32, 2), v.flat.y);
    try testing.expectEqual(@as(u32, 3), v.flat.deep.z);
    try testing.expectEqual(@as(u8, 42), v.skipped);
    // A key unknown to every level is UnknownField, matching expectedKeys.
    try testing.expectError(error.UnknownField, parseInto(T, ar.allocator(), "{\"x\":1,\"y\":2,\"z\":3,\"w\":4}", .{}));
    // The skipped field's wire name is NOT an expected key.
    try testing.expectError(error.UnknownField, parseInto(T, ar.allocator(), "{\"x\":1,\"y\":2,\"z\":3,\"skipped\":9}", .{}));
}
