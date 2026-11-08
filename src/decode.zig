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
const codec_mod = @import("codec.zig");
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
        try arena.print("{s} (at {s})", .{ msg, path.slice() })
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
        const s = std.mem.print(&tmp, "[{d}]", .{idx}) catch unreachable;
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
            for (@typeInfo(@TypeOf(T.json_rename)).@"struct".field_names) |name| {
                if (!@hasField(T, name)) {
                    @compileError("json_rename entry `" ++ name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
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

// Every annotation lookup below applies one rule: a non-null value in the
// codec's entry for `T` wins, otherwise `T`'s own declaration, otherwise the
// default. Lists replace whole, so an empty codec list clears `T`'s list.

/// Returns the effective JSON key for `field_name` on type `T`.
pub fn renamedKey(comptime T: type, comptime TCodec: type, comptime field_name: []const u8) []const u8 {
    comptime {
        if (codec_mod.entryOf(TCodec, T).json_rename) |renames| return codec_mod.renameIn(renames, field_name);
        if (!@hasDecl(T, "json_rename")) return field_name;
        const renames = T.json_rename;
        if (@hasField(@TypeOf(renames), field_name)) {
            return @field(renames, field_name);
        }
        return field_name;
    }
}

/// The wire names of enum `E`'s values through codec `TCodec`, computed
/// once per pair: `names` in declaration order, whether any differs from
/// its tag name, and lookups both ways.
pub fn EnumNames(comptime E: type, comptime TCodec: type) type {
    return struct {
        const tags = @typeInfo(E).@"enum".field_names;
        const entry_list = codec_mod.entryOf(TCodec, E).json_rename;
        const declared = @hasDecl(E, "json_rename") or entry_list != null;

        pub const names: []const []const u8 = blk: {
            @setEvalBranchQuota(1000 + 10 * tags.len);
            var out: [tags.len][]const u8 = undefined;
            if (entry_list) |list| {
                out = codec_mod.enumNamesFrom(E, list);
            } else {
                for (tags, &out) |tag, *name| name.* = renamedKey(E, TCodec, tag);
            }
            const fixed = out;
            break :blk &fixed;
        };

        /// Value indices ordered by tag name, for `nameOf`.
        const by_tag = blk: {
            @setEvalBranchQuota(1000 + 10 * tags.len);
            var plain: [tags.len][]const u8 = undefined;
            for (&plain, tags) |*p, tag| p.* = tag;
            const fixed = plain;
            break :blk codec_mod.sortedIndices(&fixed);
        };

        /// The wire name of tag `t`, found by binary search over `by_tag`.
        pub fn nameOf(comptime t: E) []const u8 {
            comptime {
                @setEvalBranchQuota(1000 + 10 * by_tag.len);
                const tag = @tagName(t);
                var lo = 0;
                var hi = by_tag.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    switch (std.mem.order(u8, tags[by_tag[mid]], tag)) {
                        .lt => lo = mid + 1,
                        .gt => hi = mid,
                        .eq => return names[by_tag[mid]],
                    }
                }
                unreachable;
            }
        }

        pub const renamed: bool = declared and blk: {
            @setEvalBranchQuota(1000 + 10 * tags.len);
            for (tags, names) |tag, name| {
                if (!std.mem.eql(u8, tag, name)) break :blk true;
            }
            break :blk false;
        };

        /// Wire name to value, for an enum with renames.
        pub const map = blk: {
            @setEvalBranchQuota(1000 + 10 * tags.len);
            var kvs: [tags.len]struct { []const u8, E } = undefined;
            for (tags, names, &kvs) |tag, name, *kv| kv.* = .{ name, @field(E, tag) };
            break :blk std.StaticStringMap(E).initComptime(kvs);
        };
    };
}

/// Comptime check of enum `E`'s `json_rename` through codec `TCodec`. The
/// enum's own declaration must be a struct mapping values of `E` to
/// strings, whatever the codec says, as `validateAnnotations` checks a
/// struct's own keys. The wire names in effect must be distinct; a codec entry's list is
/// checked when the codec is built, so here only the enum's own list can
/// collide.
pub fn validateEnumAnnotations(comptime E: type, comptime TCodec: type) void {
    comptime {
        if (@hasDecl(E, "json_rename")) {
            const R = @TypeOf(E.json_rename);
            if (@typeInfo(R) != .@"struct") {
                @compileError("json_rename on " ++ @typeName(E) ++ " must be a struct of value-name strings, got " ++ @typeName(R));
            }
            const keys = @typeInfo(R).@"struct".field_names;
            @setEvalBranchQuota(1000 + 10 * keys.len);
            for (keys) |name| {
                if (!@hasField(E, name)) {
                    @compileError("json_rename entry `" ++ name ++ "` does not match any value of " ++ @typeName(E));
                }
                const V = @TypeOf(@field(E.json_rename, name));
                if (!isString(V)) {
                    @compileError("json_rename entry `" ++ name ++ "` of " ++ @typeName(E) ++ " must be a string, got " ++ @typeName(V));
                }
            }
        }
        if (codec_mod.entryOf(TCodec, E).json_rename != null) return;
        const N = EnumNames(E, TCodec);
        if (N.renamed) codec_mod.checkEnumWireNames(E, N.names, @typeName(E) ++ ".json_rename");
    }
}

fn isString(comptime S: type) bool {
    return switch (@typeInfo(S)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// The value of enum `E` whose wire name through codec `TCodec` is `s`.
fn enumFromName(comptime E: type, comptime TCodec: type, s: []const u8) ?E {
    const N = EnumNames(E, TCodec);
    return if (comptime N.renamed) N.map.get(s) else std.meta.stringToEnum(E, s);
}

/// The wire name of `value` through codec `TCodec`, or null for an unnamed
/// value of a non-exhaustive enum.
pub fn enumName(comptime E: type, comptime TCodec: type, value: E) ?[]const u8 {
    comptime validateEnumAnnotations(E, TCodec);
    const N = EnumNames(E, TCodec);
    if (comptime @typeInfo(E).@"enum".mode == .exhaustive) {
        if (comptime !N.renamed) return @tagName(value);
        return switch (value) {
            inline else => |t| comptime N.nameOf(t),
        };
    } else {
        if (comptime @typeInfo(E).@"enum".field_names.len == 0) return null;
        return switch (value) {
            inline else => |t| comptime if (N.renamed) N.nameOf(t) else @tagName(t),
            _ => null,
        };
    }
}

fn listContains(comptime list: anytype, comptime name: []const u8) bool {
    comptime {
        for (list) |entry| {
            if (std.mem.eql(u8, entry, name)) return true;
        }
        return false;
    }
}

/// Returns true if `field_name` on type `T` is skipped.
pub fn isSkipped(comptime T: type, comptime TCodec: type, comptime field_name: []const u8) bool {
    comptime {
        if (codec_mod.entryOf(TCodec, T).json_skip) |skip| return listContains(skip, field_name);
        if (!@hasDecl(T, "json_skip")) return false;
        return listContains(T.json_skip, field_name);
    }
}

/// Returns true if `field_name` on type `T` is flattened.
pub fn isFlattened(comptime T: type, comptime TCodec: type, comptime field_name: []const u8) bool {
    comptime {
        if (codec_mod.entryOf(TCodec, T).json_flatten) |flatten| return listContains(flatten, field_name);
        if (!@hasDecl(T, "json_flatten")) return false;
        return listContains(T.json_flatten, field_name);
    }
}

/// Returns the discriminator member of tagged union `T`.
pub fn getJsonTag(comptime T: type, comptime TCodec: type) []const u8 {
    comptime {
        if (codec_mod.entryOf(TCodec, T).json_tag) |tag| return tag;
        if (@hasDecl(T, "json_tag")) return T.json_tag;
        @compileError("json: union " ++ @typeName(T) ++ " has no json_tag; declare pub const json_tag or set json_tag in its codec entry");
    }
}

/// Returns the payload member of tagged union `T`, or null when the payload
/// is inlined next to the discriminator.
pub fn getJsonPayload(comptime T: type, comptime TCodec: type) ?[]const u8 {
    comptime {
        if (codec_mod.entryOf(TCodec, T).json_payload) |payload| return payload;
        if (@hasDecl(T, "json_payload")) return T.json_payload;
        return null;
    }
}

/// The namespace whose `fromJson` / `toJson` declarations serve struct `T`:
/// the codec entry's `hooks` when set, else `T` itself.
pub fn HookSource(comptime T: type, comptime TCodec: type) type {
    return codec_mod.entryOf(TCodec, T).hooks orelse T;
}

pub const HookKind = enum { fromJson, toJson };

/// Compile-time check of the `kind` hook that `Hooks` declares for struct
/// `T`, shared by type-local hooks (`Hooks == T`) and a codec's `hooks`
/// namespace. Both get the arity check. A codec hook must also take and
/// return `T` with errors decode and encode propagate, wherever its
/// signature is concrete; parameters and return types left generic pass,
/// so aliasing a type's own generic hook works.
pub fn checkHook(comptime T: type, comptime Hooks: type, comptime kind: HookKind) void {
    comptime {
        const from_codec = Hooks != T;
        const source = if (from_codec)
            "Annotations(" ++ @typeName(T) ++ ").hooks." ++ @tagName(kind)
        else
            @typeName(T) ++ "." ++ @tagName(kind);
        const F = @TypeOf(@field(Hooks, @tagName(kind)));
        if (from_codec and @typeInfo(F) != .@"fn") {
            @compileError(source ++ " must be a function, got " ++ @typeName(F));
        }
        const fn_info = @typeInfo(F).@"fn";
        switch (kind) {
            .fromJson => if (fn_info.param_types.len != 3) {
                @compileError(source ++ " must take exactly 3 params: (Allocator, Value, ParseOptions)");
            },
            .toJson => if (fn_info.param_types.len != 2) {
                @compileError(source ++ " must take exactly 2 params: (" ++ (if (from_codec) @typeName(T) else "Self") ++ ", Allocator)");
            },
        }
        if (!from_codec) return;
        switch (kind) {
            .fromJson => if (fn_info.return_type) |R| {
                const ok = R == T or (@typeInfo(R) == .error_union and
                    @typeInfo(R).error_union.payload == T and
                    errorSetWithin(@typeInfo(R).error_union.error_set, DecodeError));
                if (!ok) {
                    @compileError(source ++ " must return " ++ @typeName(T) ++ " or E!" ++ @typeName(T) ++
                        " with E a subset of json.DecodeError, got " ++ @typeName(R));
                }
            },
            .toJson => {
                if (fn_info.param_types[0]) |P| {
                    if (P != T) @compileError(source ++ " must take " ++ @typeName(T) ++ " as its first param, got " ++ @typeName(P));
                }
                if (fn_info.return_type) |R| {
                    const ok = @typeInfo(R) == .error_union and
                        @typeInfo(R).error_union.payload == Value and
                        errorSetWithin(@typeInfo(R).error_union.error_set, Allocator.Error);
                    if (!ok) @compileError(source ++ " must return std.mem.Allocator.Error!json.Value, got " ++ @typeName(R));
                }
            },
        }
    }
}

fn errorSetWithin(comptime E: type, comptime Super: type) bool {
    comptime {
        const errors = @typeInfo(E).error_set.error_names orelse return false;
        const allowed = @typeInfo(Super).error_set.error_names.?;
        outer: for (errors) |e| {
            for (allowed) |a| {
                if (std.mem.eql(u8, e, a)) continue :outer;
            }
            return false;
        }
        return true;
    }
}

fn skipWithoutDefault(comptime T: type, comptime TCodec: type, comptime field_name: []const u8) noreturn {
    comptime {
        const msg = "`json_skip` field `" ++ field_name ++ "` on `" ++ @typeName(T) ++ "` has no default: `" ++ @typeName(T) ++
            "` can be encoded but not decoded; give `" ++ field_name ++ "` a default or a `fromJson` hook";
        const hooks = codec_mod.entryOf(TCodec, T).hooks;
        if (hooks != null and @hasDecl(T, "fromJson")) {
            @compileError(msg ++ " (`Annotations(" ++ @typeName(T) ++ ").hooks` replaces `" ++ @typeName(T) ++ ".fromJson` and declares no fromJson)");
        }
        @compileError(msg);
    }
}

/// True when struct `T` decodes through a `fromJson` hook.
pub fn hasFromJson(comptime T: type, comptime TCodec: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(HookSource(T, TCodec), "fromJson");
}

/// True when struct `T` encodes through a `toJson` hook.
pub fn hasToJson(comptime T: type, comptime TCodec: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(HookSource(T, TCodec), "toJson");
}

/// Returns the full set of JSON keys that decoding `T` expects to see
/// at the object's level -- i.e., renamed names for non-flattened fields,
/// plus the expectedKeys of each flattened field's type (recursive).
fn expectedKeys(comptime T: type, comptime TCodec: type) []const []const u8 {
    comptime {
        const s = @typeInfo(T).@"struct";
        var keys: []const []const u8 = &.{};
        for (s.field_names, s.field_types) |name, Field| {
            if (isSkipped(T, TCodec, name)) continue;
            if (isFlattened(T, TCodec, name)) {
                const inner = expectedKeys(Field, TCodec);
                keys = keys ++ inner;
            } else {
                keys = keys ++ &[_][]const u8{renamedKey(T, TCodec, name)};
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
pub fn decode(comptime T: type, comptime TCodec: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions) DecodeError!T {
    var path: PathBuilder = .{ .buf = .empty };
    return decodeInner(T, TCodec, arena, value, options, &path);
}

/// Parse + decode in one call. See `decode` for the decoding rules.
///
/// Fast path: types without `Value` fields, `fromJson` hooks, or tagged
/// unions decode in a single streaming pass with no intermediate `Value`
/// tree. On any error the input is re-decoded through the tree path, so
/// diagnostics and error selection are always the canonical ones. Callers
/// requesting `options.spans` use the tree path unconditionally.
pub fn parseInto(comptime T: type, comptime TCodec: type, arena: Allocator, src: []const u8, options: parser_mod.ParseOptions) (parser_mod.Error || DecodeError)!T {
    if (comptime needsTree(T, TCodec)) return parseIntoTree(T, TCodec, arena, src, options);
    if (options.spans != null) return parseIntoTree(T, TCodec, arena, src, options);
    return streamParseInto(T, TCodec, arena, src, options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => parseIntoTree(T, TCodec, arena, src, options),
    };
}

fn parseIntoTree(comptime T: type, comptime TCodec: type, arena: Allocator, src: []const u8, options: parser_mod.ParseOptions) (parser_mod.Error || DecodeError)!T {
    const value = try parser_mod.parse(arena, src, options);
    return decode(T, TCodec, arena, value, options);
}

/// Reader-input variant of `parseInto`: drains the reader into arena
/// memory, then decodes the slice (streaming when the type allows).
pub fn parseIntoReader(comptime T: type, comptime TCodec: type, arena: Allocator, reader: *std.Io.Reader, options: parser_mod.ParseOptions) (parser_mod.ReaderError || DecodeError)!T {
    const input = try reader.allocRemaining(arena, .unlimited);
    return parseInto(T, TCodec, arena, input, options);
}

fn decodeInner(comptime T: type, comptime TCodec: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (T == Value) return value;

    // Custom fromJson hook short-circuit.
    if (comptime hasFromJson(T, TCodec)) {
        const Hooks = HookSource(T, TCodec);
        comptime checkHook(T, Hooks, .fromJson);
        return Hooks.fromJson(arena, value, options);
    }

    // JSON `null` satisfies optionals only (handled in decodeOptional). For
    // any other target the field is effectively absent, so the error matches
    // the missing-field case.
    if (comptime @typeInfo(T) != .optional) {
        if (value == .null) {
            if (options.errors) |list| {
                const msg = try arena.print("expected {s}, got null", .{@typeName(T)});
                try appendDiag(list, arena, path, msg, null);
            }
            return error.MissingField;
        }
    }

    // Tagged-union dispatch.
    if (comptime (@typeInfo(T) == .@"union")) {
        const tag = comptime getJsonTag(T, TCodec);
        return decodeTaggedUnion(T, TCodec, tag, arena, value, options, path);
    }

    return switch (@typeInfo(T)) {
        .bool => decodeBool(value, arena, options, path),
        .int => decodeInt(T, value, arena, options, path),
        .float => decodeFloat(T, value, arena, options, path),
        .pointer => |p| decodePointer(T, TCodec, p, arena, value, options, path),
        .array => |a| decodeArray(T, TCodec, a, arena, value, options, path),
        .optional => |o| decodeOptional(o.child, TCodec, arena, value, options, path),
        .@"struct" => |s| decodeStruct(T, TCodec, s, arena, value, options, path),
        .@"enum" => decodeEnum(T, TCodec, value, arena, options, path),
        else => @compileError("json decode: unsupported type " ++ @typeName(T)),
    };
}

fn decodeBool(value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!bool {
    if (value != .bool) {
        if (options.errors) |list| {
            const msg = try arena.print("expected boolean, got {s}", .{@tagName(value)});
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
                const msg = try arena.print("integer {d} out of range for {s}", .{ n, @typeName(T) });
                try appendDiag(list, arena, path, msg, null);
            }
            return error.Overflow;
        },
        .number_raw => |raw| {
            return std.fmt.parseInt(T, raw, 10) catch |err| {
                if (options.errors) |list| {
                    const msg = switch (err) {
                        error.Overflow => try arena.print("integer {s} out of range for {s}", .{ raw, @typeName(T) }),
                        error.InvalidCharacter => try arena.print("expected integer, got number {s}", .{raw}),
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
                const msg = try arena.print("expected integer, got {s}", .{@tagName(value)});
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
                    const msg = try arena.print("expected float, got number {s}", .{raw});
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
                const msg = try arena.print("expected float, got {s}", .{@tagName(value)});
                try appendDiag(list, arena, path, msg, null);
            }
            return error.TypeMismatch;
        },
    };
}

fn decodePointer(comptime T: type, comptime TCodec: type, comptime p: std.lang.Type.Pointer, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (p.size != .slice) @compileError("json decode: only slice pointers supported, got " ++ @typeName(T));
    if (p.child == u8 and p.attrs.@"const") {
        if (value != .string) {
            if (options.errors) |list| {
                const msg = try arena.print("expected string, got {s}", .{@tagName(value)});
                try appendDiag(list, arena, path, msg, null);
            }
            return error.TypeMismatch;
        }
        return value.string;
    }
    if (value != .array) {
        if (options.errors) |list| {
            const msg = try arena.print("expected array, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    const items = value.array;
    const out = try arena.alloc(p.child, items.len);
    for (items, 0..) |item, i| {
        const prev = try path.pushIndex(arena, i);
        defer path.restore(prev);
        out[i] = try decodeInner(p.child, TCodec, arena, item, options, path);
    }
    return out;
}

fn decodeArray(comptime T: type, comptime TCodec: type, comptime a: std.lang.Type.Array, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .array) {
        if (options.errors) |list| {
            const msg = try arena.print("expected array, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    if (value.array.len != a.len) {
        if (options.errors) |list| {
            const msg = try arena.print("array length mismatch: expected {d}, got {d}", .{ a.len, value.array.len });
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
            out[i] = try decodeInner(a.child, TCodec, arena, item, options, path);
        }
    }
    return out;
}

fn decodeOptional(comptime Child: type, comptime TCodec: type, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!?Child {
    if (value == .null) return null;
    return try decodeInner(Child, TCodec, arena, value, options, path);
}

fn decodeStruct(comptime T: type, comptime TCodec: type, comptime s: std.lang.Type.Struct, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    comptime validateAnnotations(T);
    comptime codec_mod.checkUse(TCodec, T);
    if (value != .object) {
        if (options.errors) |list| {
            const msg = try arena.print("expected object, got {s}", .{@tagName(value)});
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
            inline for (comptime expectedKeys(T, TCodec)) |expected| {
                if (std.mem.eql(u8, entry.key_ptr.*, expected)) continue :outer;
            }
            // Unknown key. Try a suggestion.
            const key = entry.key_ptr.*;
            const suggestion = lev.closestMatch(key, comptime expectedKeys(T, TCodec), lev.suggestionThreshold(key.len));

            if (options.errors) |list| {
                const msg = try arena.print("unknown field `{s}`", .{key});
                const suggestion_owned: ?[]const u8 = if (suggestion) |s_str| try arena.dupe(u8, s_str) else null;
                try appendDiag(list, arena, path, msg, suggestion_owned);
            }
            return error.UnknownField;
        }
    }

    var out: T = undefined;

    inline for (s.field_names, s.field_types, s.field_attrs) |name, Field, attrs| {
        if (comptime isSkipped(T, TCodec, name)) {
            const dv = comptime attrs.defaultValue(Field) orelse skipWithoutDefault(T, TCodec, name);
            @field(out, name) = dv;
        } else if (comptime isFlattened(T, TCodec, name)) {
            // Decode the inner struct from the SAME parent value (no key lookup).
            // The parent's expectedKeys already validated all keys, so suppress
            // unknown-field errors in the inner struct to avoid false positives
            // on sibling fields the inner type doesn't know about.
            const prev = try path.pushSegment(arena, name);
            defer path.restore(prev);
            var flat_opts = options;
            flat_opts.ignore_unknown_fields = true;
            @field(out, name) = try decodeInner(Field, TCodec, arena, value, flat_opts, path);
        } else {
            const eff_key = comptime renamedKey(T, TCodec, name);
            if (obj.get(eff_key)) |fv| {
                const prev = try path.pushSegment(arena, eff_key);
                defer path.restore(prev);
                @field(out, name) = try decodeInner(Field, TCodec, arena, fv, options, path);
            } else if (attrs.defaultValue(Field)) |dv| {
                @field(out, name) = dv;
            } else if (@typeInfo(Field) == .optional) {
                @field(out, name) = null;
            } else {
                if (options.errors) |list| {
                    const msg = try arena.print("missing required field `{s}`", .{eff_key});
                    try appendDiag(list, arena, path, msg, null);
                }
                return error.MissingField;
            }
        }
    }

    return out;
}

/// Effective (renamed) wire names of every variant of union `T`.
fn variantNames(comptime T: type, comptime TCodec: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (@typeInfo(T).@"union".field_names) |name| {
            names = names ++ &[_][]const u8{renamedKey(T, TCodec, name)};
        }
        return names;
    }
}

fn decodeTaggedUnion(comptime T: type, comptime TCodec: type, comptime tag_field: []const u8, arena: Allocator, value: Value, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    comptime validateAnnotations(T);
    comptime codec_mod.checkUse(TCodec, T);
    if (value != .object) {
        if (options.errors) |list| {
            const msg = try arena.print("expected object for {s}, got {s}", .{ @typeName(T), @tagName(value) });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    const obj = value.object;
    const tag_value = obj.get(tag_field) orelse {
        if (options.errors) |list| {
            const msg = try arena.print("missing discriminator field `{s}` for {s}", .{ tag_field, @typeName(T) });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.MissingField;
    };
    if (tag_value != .string) {
        if (options.errors) |list| {
            const msg = try arena.print("expected string for discriminator `{s}`, got {s}", .{ tag_field, @tagName(tag_value) });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }

    const json_payload = comptime getJsonPayload(T, TCodec);

    const u = @typeInfo(T).@"union";
    inline for (u.field_names, u.field_types) |variant_name, PayloadType| {
        const effective_name = comptime renamedKey(T, TCodec, variant_name);
        if (std.mem.eql(u8, tag_value.string, effective_name)) {
            if (PayloadType == void) {
                return @unionInit(T, variant_name, {});
            }

            if (comptime json_payload) |jp| {
                // The payload decodes from its own member, so PayloadType may
                // be anything decodeInner supports. Unknown keys are reported
                // before a missing payload, as a struct reports them before a
                // missing field.
                if (!options.ignore_unknown_fields) {
                    const expected = [_][]const u8{ tag_field, jp };
                    var it = obj.iterator();
                    while (it.next()) |entry| {
                        const key = entry.key_ptr.*;
                        if (std.mem.eql(u8, key, tag_field) or std.mem.eql(u8, key, jp)) continue;
                        if (options.errors) |list| {
                            const suggestion = lev.closestMatch(key, &expected, lev.suggestionThreshold(key.len));
                            const msg = try arena.print("unknown field `{s}`", .{key});
                            const suggestion_owned: ?[]const u8 = if (suggestion) |s_str| try arena.dupe(u8, s_str) else null;
                            try appendDiag(list, arena, path, msg, suggestion_owned);
                        }
                        return error.UnknownField;
                    }
                }
                const payload_value = obj.get(jp) orelse {
                    if (options.errors) |list| {
                        const msg = try arena.print("missing payload field `{s}` for {s}", .{ jp, @typeName(T) });
                        try appendDiag(list, arena, path, msg, null);
                    }
                    return error.MissingField;
                };
                const prev = try path.pushSegment(arena, jp);
                defer path.restore(prev);
                const payload = try decodeInner(PayloadType, TCodec, arena, payload_value, options, path);
                return @unionInit(T, variant_name, payload);
            }

            var filtered: value_mod.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, tag_field)) continue;
                const key_dup = try arena.dupe(u8, entry.key_ptr.*);
                try filtered.put(arena, key_dup, entry.value_ptr.*);
            }
            const payload = try decodeInner(PayloadType, TCodec, arena, Value{ .object = filtered }, options, path);
            return @unionInit(T, variant_name, payload);
        }
    }
    if (options.errors) |list| {
        const tag = tag_value.string;
        const suggestion = lev.closestMatch(tag, comptime variantNames(T, TCodec), lev.suggestionThreshold(tag.len));
        const msg = try arena.print("unknown variant `{s}` for {s}", .{ tag, @typeName(T) });
        const suggestion_owned: ?[]const u8 = if (suggestion) |s_str| try arena.dupe(u8, s_str) else null;
        try appendDiag(list, arena, path, msg, suggestion_owned);
    }
    return error.InvalidEnumValue;
}

fn decodeEnum(comptime T: type, comptime TCodec: type, value: Value, arena: Allocator, options: parser_mod.ParseOptions, path: *PathBuilder) DecodeError!T {
    comptime validateEnumAnnotations(T, TCodec);
    switch (value) {
        .string => |s| {
            if (enumFromName(T, TCodec, s)) |v| return v;
            if (options.errors) |list| {
                const msg = try arena.print("invalid enum value `{s}` for {s}", .{ s, @typeName(T) });
                try appendDiag(list, arena, path, msg, null);
            }
            return error.InvalidEnumValue;
        },
        .integer => |n| {
            if (std.enums.fromInt(T, n)) |v| return v;
            if (options.errors) |list| {
                const msg = try arena.print("integer {d} is not a valid value of {s}", .{ n, @typeName(T) });
                try appendDiag(list, arena, path, msg, null);
            }
            return error.InvalidEnumValue;
        },
        else => {
            if (options.errors) |list| {
                const msg = try arena.print("expected string or integer for enum {s}, got {s}", .{ @typeName(T), @tagName(value) });
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
fn needsTree(comptime T: type, comptime TCodec: type) bool {
    return comptime needsTreeImpl(T, TCodec, &.{});
}

fn needsTreeImpl(comptime T: type, comptime TCodec: type, comptime seen: []const type) bool {
    comptime {
        for (seen) |S| if (S == T) return false;
        if (T == Value) return true;
        const seen2 = seen ++ &[_]type{T};
        return switch (@typeInfo(T)) {
            .@"struct" => |s| blk: {
                if (hasFromJson(T, TCodec)) break :blk true;
                for (s.field_names, s.field_types) |name, Field| {
                    if (isFlattened(T, TCodec, name) and @typeInfo(Field) != .@"struct") break :blk true;
                }
                if (hasKeyCollisions(T, TCodec)) break :blk true;
                for (s.field_types) |Field| {
                    if (needsTreeImpl(Field, TCodec, seen2)) break :blk true;
                }
                break :blk false;
            },
            .@"union" => true,
            .pointer => |p| p.size == .slice and !(p.child == u8 and p.attrs.@"const") and needsTreeImpl(p.child, TCodec, seen2),
            .array => |a| needsTreeImpl(a.child, TCodec, seen2),
            .optional => |o| needsTreeImpl(o.child, TCodec, seen2),
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
fn effFieldsOf(comptime T: type, comptime TCodec: type, comptime prefix: []const []const u8) []const EffField {
    comptime {
        var out: []const EffField = &.{};
        const s = @typeInfo(T).@"struct";
        for (s.field_names, s.field_types) |name, Field| {
            if (isSkipped(T, TCodec, name)) continue;
            const p2 = prefix ++ &[_][]const u8{name};
            if (isFlattened(T, TCodec, name)) {
                out = out ++ effFieldsOf(Field, TCodec, p2);
            } else {
                out = out ++ &[_]EffField{.{ .key = renamedKey(T, TCodec, name), .path = p2, .Type = Field }};
            }
        }
        return out;
    }
}

/// Two effective fields sharing one wire key (an outer field colliding
/// with a flattened inner one). The tree path decodes such a key into
/// every destination; a single token stream cannot, so collide -> tree.
fn hasKeyCollisions(comptime T: type, comptime TCodec: type) bool {
    comptime {
        const fs = effFieldsOf(T, TCodec, &.{});
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
fn assignSkippedDefaults(comptime T: type, comptime TCodec: type, comptime prefix: []const []const u8, comptime Outer: type, out: *Outer) void {
    const s = @typeInfo(T).@"struct";
    inline for (s.field_names, s.field_types, s.field_attrs) |name, Field, attrs| {
        if (comptime isSkipped(T, TCodec, name)) {
            const dv = comptime attrs.defaultValue(Field) orelse skipWithoutDefault(T, TCodec, name);
            pathPtr(Outer, prefix ++ &[_][]const u8{name}, out).* = dv;
        } else if (comptime isFlattened(T, TCodec, name)) {
            assignSkippedDefaults(Field, TCodec, prefix ++ &[_][]const u8{name}, Outer, out);
        }
    }
}

/// Streaming `parseInto`: one tokenizer pass decoding directly into `T`.
/// Success semantics match parse-then-decode exactly (same tokenizer,
/// same scalar decoders, same skip validation via `parseValue`); every
/// error abandons the pass and the caller reruns the tree path, whose
/// error selection and diagnostics are canonical.
fn streamParseInto(comptime T: type, comptime TCodec: type, arena: Allocator, src: []const u8, options: parser_mod.ParseOptions) (parser_mod.Error || DecodeError)!T {
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
    const out = try streamValue(T, TCodec, &p, t, 0);
    if (try p.next()) |_| return error.JsonParseError;
    return out;
}

fn streamValue(comptime T: type, comptime TCodec: type, p: *parser_mod.Parser, t: RawToken, depth: usize) (parser_mod.Error || DecodeError)!T {
    const info = @typeInfo(T);
    if (comptime info == .optional) {
        if (t.kind == .literal_null) return null;
        return try streamValue(info.optional.child, TCodec, p, t, depth);
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
            .string => try decodeEnum(T, TCodec, .{ .string = try p.decodeString(t) }, p.arena, p.options, &path),
            .number => try decodeEnum(T, TCodec, try p.parseNumber(t), p.arena, p.options, &path),
            else => error.TypeMismatch,
        },
        .pointer => |ptr| try streamPointer(T, TCodec, ptr, p, t, depth),
        .array => |arr| try streamFixedArray(T, TCodec, arr, p, t, depth),
        .@"struct" => try streamStruct(T, TCodec, p, t, depth),
        else => @compileError("json decode: unsupported type " ++ @typeName(T)),
    };
}

fn streamPointer(comptime T: type, comptime TCodec: type, comptime ptr: std.lang.Type.Pointer, p: *parser_mod.Parser, t: RawToken, depth: usize) (parser_mod.Error || DecodeError)!T {
    if (comptime ptr.size != .slice) @compileError("json decode: only slice pointers supported, got " ++ @typeName(T));
    if (comptime (ptr.child == u8 and ptr.attrs.@"const")) {
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
        try items.append(p.arena, try streamValue(ptr.child, TCodec, p, et, depth + 1));
        const sep = (try p.next()) orelse return error.JsonParseError;
        if (sep.kind == .array_end) break;
        if (sep.kind != .comma) return error.JsonParseError;
    }
    return items.toOwnedSlice(p.arena);
}

fn streamFixedArray(comptime T: type, comptime TCodec: type, comptime arr: std.lang.Type.Array, p: *parser_mod.Parser, t: RawToken, depth: usize) (parser_mod.Error || DecodeError)!T {
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
        out[i] = try streamValue(arr.child, TCodec, p, et, depth + 1);
        i += 1;
        const sep = (try p.next()) orelse return error.JsonParseError;
        if (sep.kind == .array_end) break;
        if (sep.kind != .comma) return error.JsonParseError;
    }
    if (i != arr.len) return error.TypeMismatch;
    return out;
}

fn streamStruct(comptime T: type, comptime TCodec: type, p: *parser_mod.Parser, t: RawToken, depth: usize) (parser_mod.Error || DecodeError)!T {
    comptime validateAnnotations(T);
    comptime codec_mod.checkUse(TCodec, T);
    if (t.kind != .object_begin) return error.TypeMismatch;
    if (depth >= p.depthLimit()) return error.NestingTooDeep;

    const eff = comptime effFieldsOf(T, TCodec, &.{});
    var seen: [eff.len]bool = @splat(false);
    var out: T = undefined;
    assignSkippedDefaults(T, TCodec, &.{}, T, &out);

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
                pathPtr(T, f.path, &out).* = try streamValue(f.Type, TCodec, p, vt, depth + 1);
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
            const ps = @typeInfo(Parent).@"struct";
            const fi = comptime std.meta.fieldIndex(Parent, f.path[f.path.len - 1]).?;
            const dv_opt = comptime ps.field_attrs[fi].defaultValue(ps.field_types[fi]);
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
const Codec = codec_mod.Codec;

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
    const cfg = try parseInto(Config, Codec(.{}), ar.allocator(),
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
    try std.testing.expectError(error.UnknownField, parseInto(C, Codec(.{}), a, "{\"prot\":2}", .{}));
    const c = try parseInto(C, Codec(.{}), a, "{\"prot\":2}", .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(u16, 1), c.port);
}

test "int overflow checked" {
    const C = struct { n: u8 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectError(error.Overflow, parseInto(C, Codec(.{}), ar.allocator(), "{\"n\":256}", .{}));
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
    const c = try parseInto(C, Codec(.{}), ar.allocator(), "{\"listen-addr\":\"x\",\"verbose\":true}", .{});
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
    const p_ = try parseInto(Plugin, Codec(.{}), ar.allocator(), "{\"kind\":\"http\",\"port\":80}", .{});
    try std.testing.expectEqual(@as(u16, 80), p_.http.port);
}

test "parseIntoReader decodes from a reader" {
    const C = struct { port: u16 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var r: std.Io.Reader = .fixed("{\"port\":8080}");
    const c = try parseIntoReader(C, Codec(.{}), ar.allocator(), &r, .{});
    try testing.expectEqual(@as(u16, 8080), c.port);
}

test "decode null into non-optional field is MissingField" {
    const C = struct { n: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.MissingField, parseInto(C, Codec(.{}), ar.allocator(), "{\"n\":null}", .{}));
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
    const c = try parseInto(C, Codec(.{}), ar.allocator(), "{\"a\":null,\"c\":3}", .{});
    try testing.expectEqual(@as(?u32, null), c.a);
    try testing.expectEqual(@as(?u32, null), c.b);
    try testing.expectEqual(@as(?u32, 3), c.c);
    try testing.expectEqual(@as(u32, 5), c.d);
}

test "decode float field accepts integer value" {
    const C = struct { x: f32, y: f64 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, Codec(.{}), ar.allocator(), "{\"x\":3,\"y\":-7}", .{});
    try testing.expectEqual(@as(f32, 3.0), c.x);
    try testing.expectEqual(@as(f64, -7.0), c.y);
}

test "decode int field rejects float value" {
    const C = struct { n: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.TypeMismatch, parseInto(C, Codec(.{}), a, "{\"n\":1.5}", .{}));
    // 1e2 lexes as .float and stays one; it never decodes into an int.
    try testing.expectError(error.TypeMismatch, parseInto(C, Codec(.{}), a, "{\"n\":1e2}", .{}));
}

test "decode int and float fields in raw number mode" {
    const C = struct { n: u32, x: f64, big: i64 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c = try parseInto(C, Codec(.{}), a, "{\"n\":42,\"x\":1.5,\"big\":9000000000}", .{ .number_mode = .raw });
    try testing.expectEqual(@as(u32, 42), c.n);
    try testing.expectEqual(@as(f64, 1.5), c.x);
    try testing.expectEqual(@as(i64, 9000000000), c.big);

    // Raw mode keeps typed-mode's policy: a float lexeme is not an int,
    // and an out-of-range integer lexeme overflows.
    const D = struct { n: u32 };
    try testing.expectError(error.TypeMismatch, parseInto(D, Codec(.{}), a, "{\"n\":1.5}", .{ .number_mode = .raw }));
    try testing.expectError(error.TypeMismatch, parseInto(D, Codec(.{}), a, "{\"n\":1e2}", .{ .number_mode = .raw }));
    try testing.expectError(error.Overflow, parseInto(D, Codec(.{}), a, "{\"n\":99999999999}", .{ .number_mode = .raw }));
}

test "decode enum from integer tag" {
    const Level = enum(u8) { debug = 0, info = 1, warn = 2, err = 3 };
    const C = struct { level: Level };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, Codec(.{}), ar.allocator(), "{\"level\":2}", .{});
    try testing.expectEqual(Level.warn, c.level);
}

test "decode enum from out-of-range integer is error" {
    const Level = enum(u8) { debug = 0, info = 1 };
    const C = struct { level: Level };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.InvalidEnumValue, parseInto(C, Codec(.{}), ar.allocator(), "{\"level\":99}", .{}));
}

test "decode enum from invalid string is error" {
    const C = struct { mode: enum { fast, slow } };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.InvalidEnumValue, parseInto(C, Codec(.{}), ar.allocator(), "{\"mode\":\"warp\"}", .{}));
}

test "decode missing required field is error" {
    const C = struct { required: []const u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.MissingField, parseInto(C, Codec(.{}), ar.allocator(), "{}", .{}));
}

test "decode fixed-size array and length mismatch" {
    const C = struct { rgb: [3]u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c = try parseInto(C, Codec(.{}), a, "{\"rgb\":[1,2,3]}", .{});
    try testing.expectEqual(@as(u8, 1), c.rgb[0]);
    try testing.expectEqual(@as(u8, 3), c.rgb[2]);
    try testing.expectError(error.TypeMismatch, parseInto(C, Codec(.{}), a, "{\"rgb\":[1,2]}", .{}));
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
    const c = try parseInto(C, Codec(.{}), ar.allocator(), "{\"a\":{\"b\":{\"c\":{\"n\":42}}}}", .{});
    try testing.expectEqual(@as(u32, 42), c.a.b.c.n);
}

test "decode slice of structs" {
    const User = struct { name: []const u8, age: u32 };
    const C = struct { users: []const User };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, Codec(.{}), ar.allocator(), "{\"users\":[{\"name\":\"alice\",\"age\":30},{\"name\":\"bob\",\"age\":25}]}", .{});
    try testing.expectEqual(@as(usize, 2), c.users.len);
    try testing.expectEqualStrings("alice", c.users[0].name);
    try testing.expectEqual(@as(u32, 25), c.users[1].age);
}

test "decode embedded Value field keeps dynamic subtree" {
    const C = struct { meta: Value, n: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, Codec(.{}), ar.allocator(), "{\"meta\":{\"a\":[1,2]},\"n\":5}", .{});
    try testing.expectEqual(@as(u32, 5), c.n);
    try testing.expect(c.meta == .object);
    try testing.expectEqual(@as(i64, 2), c.meta.getT(i64, "a[1]").?);
}

test "decode raw Value passthrough at any variant" {
    const C = struct { anything: Value };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c = try parseInto(C, Codec(.{}), a, "{\"anything\":\"goes\"}", .{});
    try testing.expectEqualStrings("goes", c.anything.string);
    // `null` is a Value variant, so it passes through rather than erroring.
    const c2 = try parseInto(C, Codec(.{}), a, "{\"anything\":null}", .{});
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
    const c = try parseInto(C, Codec(.{}), ar.allocator(), "{\"v\":\"1.2.3\"}", .{});
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
    try testing.expectError(error.UnknownField, parseInto(C, Codec(.{}), ar.allocator(), "{\"listen_addr\":\"0.0.0.0\"}", .{}));
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
    try testing.expectError(error.UnknownField, parseInto(C, Codec(.{}), ar.allocator(), "{\"name\":\"foo\",\"internal\":99}", .{}));
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
    const c = try parseInto(Outer, Codec(.{}), ar.allocator(), "{\"listen-addr\":\"x\",\"log-level\":\"debug\"}", .{});
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
    try testing.expectError(error.UnknownField, parseInto(Outer, Codec(.{}), ar.allocator(), "{\"name\":\"foo\",\"x\":42,\"unexpected\":true}", .{}));
}

test "decode: tagged union missing discriminator -> MissingField" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        http: struct { host: []const u8 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.MissingField, parseInto(Plugin, Codec(.{}), ar.allocator(), "{\"host\":\"localhost\"}", .{}));
}

test "decode: tagged union unknown discriminator -> InvalidEnumValue" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        http: struct { host: []const u8 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.InvalidEnumValue, parseInto(Plugin, Codec(.{}), ar.allocator(), "{\"kind\":\"xyz\",\"host\":\"localhost\"}", .{}));
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

    _ = parseInto(Plugin, Codec(.{}), a, "{\"kind\":\"htpp\"}", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.find(u8, errs.items[0].message, "unknown variant `htpp`") != null);
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

    _ = parseInto(Plugin, Codec(.{}), a, "{\"port\":80}", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.find(u8, errs.items[0].message, "missing discriminator field `kind`") != null);
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

    _ = parseInto(C, Codec(.{}), a, "{}", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.find(u8, errs.items[0].message, "`listen-addr`") != null);
    try testing.expect(std.mem.find(u8, errs.items[0].message, "listen_addr") == null);
}

test "decode: tagged union void variant" {
    const Plugin = union(enum) {
        pub const json_tag = "kind";
        none,
        http: struct { port: u16 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const p_ = try parseInto(Plugin, Codec(.{}), ar.allocator(), "{\"kind\":\"none\"}", .{});
    try testing.expect(p_ == .none);
}

test "decode: tagged union struct payload" {
    const Component = union(enum) {
        pub const json_tag = "@kind";
        pub const json_payload = "@payload";

        AttackComparison: struct { ComparisonOperator: bool, AttackValue: u8 },
        Subset: []const u8,
        None: void,
    };

    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const src = "{\"@kind\":\"AttackComparison\",\"@payload\":{\"ComparisonOperator\":true,\"AttackValue\":15}}";
    const c = try parseInto(Component, Codec(.{}), a, src, .{});
    try testing.expectEqual(true, c.AttackComparison.ComparisonOperator);
    try testing.expectEqual(@as(u8, 15), c.AttackComparison.AttackValue);
}

test "decode: tagged union scalar payload" {
    const Component = union(enum) {
        pub const json_tag = "@kind";
        pub const json_payload = "@payload";

        AttackComparison: struct { ComparisonOperator: bool, AttackValue: u8 },
        Subset: []const u8,
        None: void,
    };

    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const src = "{\"@kind\":\"Subset\",\"@payload\":\"base\"}";
    const c = try parseInto(Component, Codec(.{}), a, src, .{});
    try testing.expectEqualStrings("base", c.Subset);
}

test "decode: tagged union void payload" {
    const Component = union(enum) {
        pub const json_tag = "@kind";
        pub const json_payload = "@payload";

        AttackComparison: struct { ComparisonOperator: bool, AttackValue: u8 },
        Subset: []const u8,
        None: void,
    };

    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const src = "{\"@kind\":\"None\"}";
    const c = try parseInto(Component, Codec(.{}), a, src, .{});
    try testing.expect(c == .None);
}

test "decode: tagged union without json_payload accepts any decodable payload" {
    const Inner = union(enum) {
        pub const json_tag = "sub";
        a: struct { x: u8 },
        b: void,
    };
    const U = union(enum) {
        pub const json_tag = "kind";
        raw: Value,
        nested: Inner,
        maybe: ?struct { y: u8 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const raw = try parseInto(U, Codec(.{}), a, "{\"kind\":\"raw\",\"p\":1}", .{});
    try testing.expectEqual(@as(i128, 1), raw.raw.object.get("p").?.integer);
    try testing.expectEqual(@as(usize, 1), raw.raw.object.count());

    const nested = try parseInto(U, Codec(.{}), a, "{\"kind\":\"nested\",\"sub\":\"a\",\"x\":3}", .{});
    try testing.expectEqual(@as(u8, 3), nested.nested.a.x);

    const tree = try parse(a, "{\"kind\":\"maybe\",\"y\":4}", .{});
    const maybe = try decode(U, Codec(.{}), a, tree, .{});
    try testing.expectEqual(@as(u8, 4), maybe.maybe.?.y);
}

test "decode: json_payload diagnostics: unknown key first with a suggestion, dotted path into the payload" {
    const U = union(enum) {
        pub const json_tag = "kind";
        pub const json_payload = "value";
        version: struct { major: u8 },
        none: void,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
    try testing.expectError(error.UnknownField, parseInto(U, Codec(.{}), a, "{\"kind\":\"version\",\"valeu\":{\"major\":1}}", .{ .errors = &errs }));
    try testing.expectEqual(@as(usize, 1), errs.items.len);
    try testing.expectEqualStrings("unknown field `valeu`", errs.items[0].message);
    try testing.expectEqualStrings("value", errs.items[0].suggestion.?);

    errs = .empty;
    try testing.expectError(error.MissingField, parseInto(U, Codec(.{}), a, "{\"kind\":\"version\"}", .{ .errors = &errs }));
    try testing.expectEqualStrings("missing payload field `value` for " ++ @typeName(U), errs.items[0].message);

    errs = .empty;
    try testing.expectError(error.TypeMismatch, parseInto(U, Codec(.{}), a, "{\"kind\":\"version\",\"value\":{\"major\":\"1\"}}", .{ .errors = &errs }));
    try testing.expectEqualStrings("expected integer, got string (at value.major)", errs.items[0].message);

    const Outer = struct { u: U };
    errs = .empty;
    try testing.expectError(error.TypeMismatch, parseInto(Outer, Codec(.{}), a, "{\"u\":{\"kind\":\"version\",\"value\":[]}}", .{ .errors = &errs }));
    try testing.expectEqualStrings("expected object, got array (at u.value)", errs.items[0].message);
}

test "decode: unknown field suggests closest match" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
    defer errs.deinit(a);

    // `prt` is a typo for `port`; `port` is also present so the required
    // field is satisfied and the unknown-field check runs.
    const C = struct { port: u16 };
    _ = parseInto(C, Codec(.{}), a, "{\"port\":8080,\"prt\":9090}", .{ .errors = &errs }) catch {};

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
    _ = parseInto(C, Codec(.{}), a, "{\"server\":{\"port\":\"8080\"}}", .{ .errors = &errs }) catch {};

    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.find(u8, errs.items[0].message, "server.port") != null);
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
    const cfg = try decode(Config, Codec(.{}), a, v, .{});
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
    try encoder_mod.encodeTyped(Codec(.{}), &aw.writer, orig, a, .{});
    // "18446744073709551615" must appear verbatim in the encoded output.
    try testing.expect(std.mem.find(u8, aw.written(), "18446744073709551615") != null);
    const back = try parseInto(S, Codec(.{}), a, aw.written(), .{});
    try testing.expectEqual(std.math.maxInt(u64), back.n);
}

test "wide-int round-trip: i128 extremes via number_mode=.raw" {
    const S = struct { n: i128 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const back_max = try parseInto(S, Codec(.{}), a, "{\"n\":170141183460469231731687303715884105727}", .{ .number_mode = .raw });
    try testing.expectEqual(std.math.maxInt(i128), back_max.n);
    const back_min = try parseInto(S, Codec(.{}), a, "{\"n\":-170141183460469231731687303715884105728}", .{ .number_mode = .raw });
    try testing.expectEqual(std.math.minInt(i128), back_min.n);
}

test "wide-int round-trip: u128 max via number_mode=.raw" {
    const S = struct { n: u128 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const back = try parseInto(S, Codec(.{}), a, "{\"n\":340282366920938463463374607431768211455}", .{ .number_mode = .raw });
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
    const c = try parseInto(S, Codec(.{}), a, "{\"a\":-9223372036854775808,\"b\":7}", .{});
    try testing.expectEqual(std.math.minInt(i64), c.a);
    try testing.expectEqual(@as(i32, 7), c.b);
}

test "decode float narrowing overflow is Overflow" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const C32 = struct { x: f32 };
    // 1e40 is finite as f64 but overflows f32 (~3.4e38 max).
    try testing.expectError(error.Overflow, parseInto(C32, Codec(.{}), a, "{\"x\":1e40}", .{}));
    // 3.5e38 is a float literal (stored as .float) that overflows f32.
    try testing.expectError(error.Overflow, parseInto(C32, Codec(.{}), a, "{\"x\":3.5e38}", .{}));
    // 3.0e38 is within f32 range -- must succeed.
    const c = try parseInto(C32, Codec(.{}), a, "{\"x\":3.0e38}", .{});
    try testing.expect(!std.math.isInf(c.x));

    // Integer 66000 overflows f16 (max 65504) via @floatFromInt.
    const C16 = struct { x: f16 };
    try testing.expectError(error.Overflow, parseInto(C16, Codec(.{}), a, "{\"x\":66000}", .{}));

    // f64 target with 1e40 -- no narrowing, finite result passes through.
    const C64 = struct { x: f64 };
    const c64 = try parseInto(C64, Codec(.{}), a, "{\"x\":1e40}", .{});
    try testing.expect(!std.math.isInf(c64.x));
}

test "decode zero-length fixed array field compiles and decodes" {
    const C = struct { xs: [0]u8, name: []const u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Empty JSON array for [0]u8 field must compile and decode successfully.
    const c = try parseInto(C, Codec(.{}), a, "{\"xs\":[],\"name\":\"ok\"}", .{});
    try testing.expectEqual([0]u8{}, c.xs);
    try testing.expectEqualStrings("ok", c.name);
    // Non-empty JSON array for [0]u8 field must be TypeMismatch (length mismatch).
    try testing.expectError(error.TypeMismatch, parseInto(C, Codec(.{}), a, "{\"xs\":[1],\"name\":\"ok\"}", .{}));
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
        const rec = try std.mem.print(&buf, "{{\"id\":{d},\"name\":\"record-{d}\",\"active\":{},\"score\":{d}.5,\"tags\":[\"a\",\"b\"]}}", .{ i, i, i % 2 == 0, i % 100 });
        try src.appendSlice(testing.allocator, rec);
    }
    try src.append(testing.allocator, ']');

    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var counting: CountingAllocator = .{ .child = ar.allocator() };

    const out = try parseInto([]const Rec, Codec(.{}), counting.allocator(), src.items, .{});
    try testing.expectEqual(@as(usize, 2000), out.len);
    try testing.expectEqualStrings("record-1999", out[1999].name);

    var tree_arena = ArenaAllocator.init(testing.allocator);
    defer tree_arena.deinit();
    var tree_counting: CountingAllocator = .{ .child = tree_arena.allocator() };
    const tree_out = try parseIntoTree([]const Rec, Codec(.{}), tree_counting.allocator(), src.items, .{});
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
    const v = try parseInto(T, Codec(.{}), ar.allocator(), "{\"a\":\"not an int\",\"a\":7}", .{});
    try testing.expectEqual(@as(u32, 7), v.a);
}

test "streaming equivalence: unknown field wins over earlier type error" {
    // decodeStruct checks unknown keys over the whole object before any
    // field decode, so UnknownField must surface even when an earlier
    // field value would TypeMismatch.
    const T = struct { a: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.UnknownField, parseInto(T, Codec(.{}), ar.allocator(), "{\"a\":\"bad\",\"zzz\":1}", .{}));
}

test "streaming: jsonc comments and trailing commas decode typed" {
    const T = struct { a: u32, tags: []const []const u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const v = try parseInto(T, Codec(.{}), ar.allocator(),
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
    const v = try parseInto(T, Codec(.{}), ar.allocator(), "{\"na\\u006de\":5}", .{});
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
    try testing.expectError(error.NestingTooDeep, parseInto(T, Codec(.{}), ar.allocator(), src.items, .{ .ignore_unknown_fields = true }));
}

test "streaming: u128 beyond i128 range errors typed, decodes raw" {
    const T = struct { n: u128 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const big = "{\"n\":200000000000000000000000000000000000000}";
    // Typed mode: the tree stores integers as i128 (overflow falls back to
    // float), so the streaming pass must not sneak a wider direct parse in.
    try testing.expectError(error.TypeMismatch, parseInto(T, Codec(.{}), ar.allocator(), big, .{}));
    // Raw mode: the verbatim lexeme decodes straight into u128, both paths.
    const v = try parseInto(T, Codec(.{}), ar.allocator(), big, .{ .number_mode = .raw });
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
    const v = try parseInto(T, Codec(.{}), ar.allocator(), "{\"x\":1,\"y\":2,\"z\":3}", .{});
    try testing.expectEqual(@as(u32, 1), v.x);
    try testing.expectEqual(@as(u32, 2), v.flat.y);
    try testing.expectEqual(@as(u32, 3), v.flat.deep.z);
    try testing.expectEqual(@as(u8, 42), v.skipped);
    // A key unknown to every level is UnknownField, matching expectedKeys.
    try testing.expectError(error.UnknownField, parseInto(T, Codec(.{}), ar.allocator(), "{\"x\":1,\"y\":2,\"z\":3,\"w\":4}", .{}));
    // The skipped field's wire name is NOT an expected key.
    try testing.expectError(error.UnknownField, parseInto(T, Codec(.{}), ar.allocator(), "{\"x\":1,\"y\":2,\"z\":3,\"skipped\":9}", .{}));
}

// Enum renames

/// Decodes `src` as `T` through codec `C` on all three paths: the streaming
/// pass alone (for a type that streams), `parseInto`, and the tree. The
/// streaming pass is called directly because `parseInto` reruns the tree
/// after a streaming error.
fn expectDecodesAll(comptime T: type, comptime C: type, src: []const u8, want: T) !void {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    if (comptime !needsTree(T, C)) try testing.expectEqual(want, try streamParseInto(T, C, a, src, .{}));
    try testing.expectEqual(want, try parseInto(T, C, a, src, .{}));
    try testing.expectEqual(want, try decode(T, C, a, try parser_mod.parse(a, src, .{}), .{}));
}

fn expectRejectsAll(comptime T: type, comptime C: type, src: []const u8, want: anyerror) !void {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    if (comptime !needsTree(T, C)) try testing.expectError(want, streamParseInto(T, C, a, src, .{}));
    try testing.expectError(want, parseInto(T, C, a, src, .{}));
    try testing.expectError(want, decode(T, C, a, try parser_mod.parse(a, src, .{}), .{}));
}

fn expectEncodes(comptime C: type, value: anytype, options: @import("encoder.zig").EncodeOptions, want: []const u8) !void {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    try @import("encoder.zig").encodeTyped(C, &aw.writer, value, a, options);
    try testing.expectEqualStrings(want, aw.written());
}

const RenamedLevel = enum(u8) {
    pub const json_rename = .{ .warn = "warning", .err = "error" };

    debug,
    info,
    warn,
    err,
};

test "enum rename: a renamed value decodes from its JSON name only" {
    const S = struct { level: RenamedLevel };
    const L = Codec(.{});
    try expectDecodesAll(S, L, "{\"level\":\"warning\"}", .{ .level = .warn });
    try expectDecodesAll(S, L, "{\"level\":\"error\"}", .{ .level = .err });
    try expectDecodesAll(S, L, "{\"level\":\"debug\"}", .{ .level = .debug });
    try expectRejectsAll(S, L, "{\"level\":\"warn\"}", error.InvalidEnumValue);
    try expectRejectsAll(S, L, "{\"level\":\"err\"}", error.InvalidEnumValue);
    try expectDecodesAll(RenamedLevel, L, "\"warning\"", .warn);
    try expectRejectsAll(RenamedLevel, L, "\"warn\"", error.InvalidEnumValue);
}

test "enum rename: integer tags decode whatever the renames" {
    const S = struct { level: RenamedLevel };
    const L = Codec(.{});
    try expectDecodesAll(S, L, "{\"level\":2}", .{ .level = .warn });
    try expectRejectsAll(S, L, "{\"level\":9}", error.InvalidEnumValue);
}

test "enum rename: the diagnostic quotes the string received" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errors: std.ArrayList(parser_mod.Diagnostic) = .empty;
    const S = struct { level: RenamedLevel };
    try testing.expectError(error.InvalidEnumValue, parseInto(S, Codec(.{}), a, "{\"level\":\"warn\"}", .{ .errors = &errors }));
    try testing.expectEqual(@as(usize, 1), errors.items.len);
    try testing.expectEqualStrings("invalid enum value `warn` for " ++ @typeName(RenamedLevel) ++ " (at level)", errors.items[0].message);
}

test "enum rename: encodeTyped writes JSON names and round-trips" {
    const S = struct { a: RenamedLevel, b: RenamedLevel, list: []const RenamedLevel };
    const v: S = .{ .a = .warn, .b = .info, .list = &.{ .err, .debug } };
    const want = "{\"a\":\"warning\",\"b\":\"info\",\"list\":[\"error\",\"debug\"]}";
    try expectEncodes(Codec(.{}), v, .{}, want);
    try expectEncodes(Codec(.{}), v, .{ .sort_keys = true }, want);
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const back = try parseInto(S, Codec(.{}), ar.allocator(), want, .{});
    try testing.expectEqual(v.a, back.a);
    try testing.expectEqual(v.b, back.b);
    try testing.expectEqualSlices(RenamedLevel, v.list, back.list);
}

test "enum rename: swapped names and an empty name" {
    const Swap = enum {
        pub const json_rename = .{ .a = "b", .b = "a" };
        a,
        b,
    };
    const L = Codec(.{});
    try expectDecodesAll(Swap, L, "\"b\"", .a);
    try expectDecodesAll(Swap, L, "\"a\"", .b);
    try expectEncodes(L, Swap.a, .{}, "\"b\"");
    const Empty = enum {
        pub const json_rename = .{ .none = "" };
        none,
        some,
    };
    try expectDecodesAll(Empty, L, "\"\"", .none);
    try expectRejectsAll(Empty, L, "\"none\"", error.InvalidEnumValue);
    try expectEncodes(L, Empty.none, .{}, "\"\"");
}

test "enum rename: an enum with no values takes an empty entry" {
    const Z = enum {};
    const C = Codec(.{codec_mod.Annotations(Z){ .json_rename = &.{} }});
    try expectRejectsAll(Z, C, "\"a\"", error.InvalidEnumValue);
}

test "enum rename: a non-exhaustive enum decodes names and integers" {
    const N = enum(u8) {
        pub const json_rename = .{ .a = "A" };
        a,
        b,
        _,
    };
    const L = Codec(.{});
    try expectDecodesAll(N, L, "\"A\"", .a);
    try expectDecodesAll(N, L, "\"b\"", .b);
    try expectRejectsAll(N, L, "\"a\"", error.InvalidEnumValue);
    try expectDecodesAll(N, L, "7", @fromBackingInt(@intCast(7)));
    try expectEncodes(L, N.a, .{}, "\"A\"");
    try expectEncodes(L, N.b, .{}, "\"b\"");
}

test "enum rename: a codec entry overrides, falls back, and clears" {
    const S = struct { level: RenamedLevel };
    const Override = Codec(.{codec_mod.Annotations(RenamedLevel){ .json_rename = &.{.{ .zig_name = "info", .json_name = "notice" }} }});
    try expectDecodesAll(S, Override, "{\"level\":\"notice\"}", .{ .level = .info });
    try expectDecodesAll(S, Override, "{\"level\":\"warn\"}", .{ .level = .warn });
    try expectRejectsAll(S, Override, "{\"level\":\"warning\"}", error.InvalidEnumValue);
    try expectRejectsAll(S, Override, "{\"level\":\"info\"}", error.InvalidEnumValue);
    try expectEncodes(Override, S{ .level = .info }, .{}, "{\"level\":\"notice\"}");

    const Fallback = Codec(.{codec_mod.Annotations(RenamedLevel){}});
    try expectDecodesAll(S, Fallback, "{\"level\":\"warning\"}", .{ .level = .warn });
    try expectRejectsAll(S, Fallback, "{\"level\":\"warn\"}", error.InvalidEnumValue);

    const Clear = Codec(.{codec_mod.Annotations(RenamedLevel){ .json_rename = &.{} }});
    try expectDecodesAll(S, Clear, "{\"level\":\"warn\"}", .{ .level = .warn });
    try expectRejectsAll(S, Clear, "{\"level\":\"warning\"}", error.InvalidEnumValue);
    try expectEncodes(Clear, S{ .level = .warn }, .{}, "{\"level\":\"warn\"}");
}

test "enum rename: a codec entry replaces an enum's own colliding names" {
    const Clash = enum {
        pub const json_rename = .{ .p = "z", .q = "z" };
        p,
        q,
    };
    const C = Codec(.{codec_mod.Annotations(Clash){ .json_rename = &.{} }});
    try expectDecodesAll(Clash, C, "\"q\"", .q);
    try expectEncodes(C, Clash.p, .{}, "\"p\"");
}

test "enum rename: a codec entry applies wherever the enum appears" {
    const E = @Enum(u8, .exhaustive, &.{ "one", "two" }, &.{ 0, 1 });
    const C = Codec(.{codec_mod.Annotations(E){ .json_rename = &.{.{ .zig_name = "two", .json_name = "2nd" }} }});
    const Holder = struct {
        opt: ?E = null,
        many: []const E = &.{},
        fixed: [2]E = .{ .one, .one },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{\"opt\":\"2nd\",\"many\":[\"one\",\"2nd\"],\"fixed\":[\"2nd\",\"one\"]}";
    for ([_]Holder{
        try streamParseInto(Holder, C, a, src, .{}),
        try decode(Holder, C, a, try parser_mod.parse(a, src, .{}), .{}),
    }) |h| {
        try testing.expectEqual(@as(?E, .two), h.opt);
        try testing.expectEqualSlices(E, &.{ .one, .two }, h.many);
        try testing.expectEqual([2]E{ .two, .one }, h.fixed);
    }
    try expectEncodes(C, Holder{ .opt = .two, .many = &.{.two}, .fixed = .{ .one, .two } }, .{}, "{\"opt\":\"2nd\",\"many\":[\"2nd\"],\"fixed\":[\"one\",\"2nd\"]}");

    const Inner = struct { e: E };
    const Flat = struct {
        pub const json_flatten = .{"inner"};
        inner: Inner,
    };
    try expectDecodesAll(Flat, C, "{\"e\":\"2nd\"}", .{ .inner = .{ .e = .two } });
    try expectEncodes(C, Flat{ .inner = .{ .e = .two } }, .{}, "{\"e\":\"2nd\"}");

    const Inline = union(enum) {
        pub const json_tag = "t";
        x: Inner,
    };
    try expectDecodesAll(Inline, C, "{\"t\":\"x\",\"e\":\"2nd\"}", .{ .x = .{ .e = .two } });
    try expectEncodes(C, Inline{ .x = .{ .e = .two } }, .{}, "{\"t\":\"x\",\"e\":\"2nd\"}");

    const Boxed = union(enum) {
        pub const json_tag = "t";
        pub const json_payload = "v";
        x: E,
    };
    try expectDecodesAll(Boxed, C, "{\"t\":\"x\",\"v\":\"2nd\"}", .{ .x = .two });
    try expectEncodes(C, Boxed{ .x = .two }, .{}, "{\"t\":\"x\",\"v\":\"2nd\"}");
}

test "enum rename: a union's discriminator keeps the union's own names" {
    const Kind = enum {
        pub const json_rename = .{ .a = "AA" };
        a,
        b,
    };
    const U = union(Kind) {
        pub const json_tag = "t";
        a: void,
        b: void,
    };
    const S = struct { k: Kind, u: U };
    const L = Codec(.{});
    try expectDecodesAll(S, L, "{\"k\":\"AA\",\"u\":{\"t\":\"a\"}}", .{ .k = .a, .u = .a });
    try expectEncodes(L, S{ .k = .a, .u = .a }, .{}, "{\"k\":\"AA\",\"u\":{\"t\":\"a\"}}");
}

fn bigEnumNames(comptime n: usize) [n][]const u8 {
    @setEvalBranchQuota(1000 * n);
    var names: [n][]const u8 = undefined;
    for (&names, 0..) |*name, i| name.* = std.fmt.comptimePrint("v{d}", .{i});
    return names;
}

test "enum rename: large enums compile, with and without renames" {
    const n = 300;
    const names = comptime bigEnumNames(n);
    const Big = @Enum(u16, .exhaustive, &names, &std.simd.iota(u16, n));
    const L = Codec(.{});
    try expectDecodesAll(Big, L, "\"v299\"", .v299);
    try expectEncodes(L, Big.v150, .{}, "\"v150\"");

    const renames = comptime blk: {
        @setEvalBranchQuota(100 * n);
        var out: [n]codec_mod.AnnotationRename = undefined;
        for (&out, names) |*r, name| r.* = .{ .zig_name = name, .json_name = "w" ++ name[1..] };
        break :blk out;
    };
    const C = Codec(.{codec_mod.Annotations(Big){ .json_rename = &renames }});
    try expectRejectsAll(Big, C, "\"v299\"", error.InvalidEnumValue);
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    inline for (0..n) |i| {
        const value: Big = @field(Big, names[i]);
        var aw: std.Io.Writer.Allocating = .init(a);
        try @import("encoder.zig").encodeTyped(C, &aw.writer, value, a, .{});
        try testing.expectEqualStrings("\"" ++ renames[i].json_name ++ "\"", aw.written());
        try testing.expectEqual(value, try parseInto(Big, C, a, aw.written(), .{}));
    }
}
