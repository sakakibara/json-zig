//! Type annotation utilities for typed encoding and decoding.
//!
//! Reasoning:
//! 1. Adding metadata to types from other packages;
//! 2. Support comptime-generated types from @Struct and @Union, where
//! embedding annotations by declaring fields is currently impossible /
//! undesirable behavior;
//! 3. Allow to overwrite default annotations for specific files when needed.

const std = @import("std");
const parser_mod = @import("parser.zig");
const decode_mod = @import("decode.zig");
const encoder_mod = @import("encoder.zig");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
const Error = parser_mod.Error;
const ParseOptions = parser_mod.ParseOptions;
const EncodeOptions = encoder_mod.EncodeOptions;
const ReaderError = parser_mod.ReaderError;
const DecodeError = decode_mod.DecodeError;
const EncodeError = encoder_mod.EncodeError;
const Value = value_mod.Value;

/// One `json_rename` pair: the Zig field or variant name and the JSON key
/// it maps to, the same direction as a type-local
/// `.{ .zig_field = "json-name" }`.
pub const AnnotationRename = struct {
    zig_name: []const u8,
    json_name: []const u8,
};

/// Annotations for `T` supplied from outside it, for types that cannot
/// carry declarations. Every field defaults to null, meaning "no override".
pub fn Annotations(comptime T: type) type {
    return struct {
        const associated_type: type = T;

        /// Field or variant name overrides.
        json_rename: ?[]const AnnotationRename = null,
        /// Struct fields whose members are read from and written to the
        /// parent object.
        json_flatten: ?[]const []const u8 = null,
        /// Fields excluded from decode and encode.
        json_skip: ?[]const []const u8 = null,

        /// A namespace declaring `fromJson` and/or `toJson` for struct `T`,
        /// with the type-local hooks' signatures. When set, it replaces both
        /// of `T`'s own hooks: a direction it does not declare uses built-in
        /// reflection, and `struct {}` clears both. Keep one of `T`'s own with
        /// `pub const fromJson = T.fromJson;`. Hook bodies name `T` explicitly,
        /// since `@This()` inside the namespace is the namespace. Hooks receive
        /// no codec: a hook that decodes children through `json.decode` does
        /// not see this codec's entries for them.
        hooks: ?type = null,

        /// Discriminator member of a tagged union.
        json_tag: ?[]const u8 = null,
        /// Member of a tagged union that holds the active variant's payload.
        json_payload: ?[]const u8 = null,
    };
}

/// Constructs annotation for typed encoding and decoding.
// Usage:
// ```zig
// fn ComponentUnion(comptime container: []const u8, comptime specs: anytype) type {
//     var field_names: [specs.len][]const u8 = undefined;
//     var field_types: [specs.len]type = undefined;
//     var field_attrs: [specs.len]FieldAttributes = undefined;
//     ...
//     const Tag = ComponentEnum(container, specs);
//     return @Union(.auto, Tag, &field_names, &field_types, &field_attrs);
// }
//
// const _CardDescriptor: json.Annotations(card_descriptor.CardDescriptor) = .{
//     .json_rename = &.{
//         .{ .zig_name = "abilities", .json_name = "special_abilities" },
//         .{ .zig_name = "tags", .json_name = "extra_tags" },
//     },
//     .json_skip = &[_][]const u8{ ... },
// };
// const _Component: json.Annotations(Component) = .{ .json_tag = "$type" };
// const _EffectEntityComponent: json.Annotations(EffectEntityComponent) = .{ .json_tag = "$type" };
// const _Query: json.Annotations(Query) = .{
//     .json_tag = "$type",
//     .json_rename = &.{
//         .{ .zig_name = "AlwaysMatches", .json_name = "AlwaysMatchesQuery" },
//     },
// };
// pub const ComponentUnionRegistry = json.Codec(.{ _CardDescriptor, _Component, ..., _Query });
// ```
pub fn Codec(comptime entries: anytype) type {
    comptime {
        for (entries, 0..) |annotation, i| {
            const TOption = @TypeOf(annotation);
            if (!@hasDecl(TOption, "associated_type")) break;

            const T = TOption.associated_type;
            if (TOption != Annotations(T)) break;

            for (0..i) |j| {
                const TPrev = @TypeOf(entries[j]);
                if (TPrev.associated_type == T) {
                    @compileError("Duplicate Annotations(T) entry found for " ++ @typeName(T));
                }
            }

            const kind = if (@typeInfo(T) == .@"union") "variant" else "field";
            if (annotation.json_rename) |rename| {
                for (rename) |rf| {
                    if (!@hasField(T, rf.zig_name)) {
                        @compileError("json_rename entry `" ++ rf.zig_name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                    }
                }
            }
            if (annotation.json_skip) |skip| {
                for (skip) |name| {
                    if (!@hasField(T, name)) {
                        @compileError("json_skip entry `" ++ name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                    }
                }
            }
            if (annotation.json_flatten) |flatten| {
                for (flatten) |name| {
                    if (!@hasField(T, name)) {
                        @compileError("json_flatten entry `" ++ name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                    }
                }
            }

            if (annotation.hooks) |Hooks| checkHooksNamespace(T, Hooks);

            if (@typeInfo(T) == .@"union" and
                annotation.json_tag != null and
                annotation.json_payload != null and
                std.mem.eql(u8, annotation.json_tag.?, annotation.json_payload.?))
            {
                @compileError("json_tag and json_payload collision - cannot share the field name.");
            }
        } else return struct {
            const annotations = entries;
            const Self = @This();

            /// Decode a parsed `Value` tree into `T` via comptime reflection.
            /// Supports bool, ints (overflow-checked), floats, `[]const u8`,
            /// slices, fixed-size arrays, optionals, nested structs, enums (string
            /// name or integer tag), tagged unions via `json_tag`, embedded `Value`
            /// fields (kept dynamic), custom `fromJson` hooks, and the
            /// `json_rename` / `json_skip` / `json_flatten` / `json_payload`
            /// annotations, each annotation and hook taken from this codec's entry
            /// for the type when non-null, else from the type's own declarations.
            ///
            /// Number policy: float targets accept `.integer` values, but integer
            /// targets do NOT accept `.float` -- `1e2` parses as `.float` and stays
            /// one. In typed mode, integer literals in the range [minInt(i128),
            /// maxInt(i128)] decode into any integer target that fits (overflow
            /// returns `error.Overflow`). For u128 or literals beyond i128 range,
            /// use `number_mode = .raw` so the lexeme decodes directly into the
            /// target. JSON `null` decodes only into optional targets; anywhere else
            /// it errors like an absent field. See `src/decode.zig`.
            pub fn decode(comptime T: type, arena: std.mem.Allocator, value: Value, options: ParseOptions) DecodeError!T {
                return decode_mod.decode(T, Self, arena, value, options);
            }

            /// Decode `src` directly into a `T` using this codec's entries.
            /// Types without `Value` fields, `fromJson` hooks, or tagged unions decode in
            /// a single streaming pass with no intermediate `Value` tree; other types
            /// (and calls requesting `options.spans`) parse to a tree first. Both paths
            /// accept and reject identically. All allocations land in `arena`; string
            /// fields may be zero-copy slices into `src`, so keep `src` alive while the
            /// result is in use.
            pub fn parseInto(comptime T: type, arena: std.mem.Allocator, src: []const u8, options: ParseOptions) (Error || DecodeError)!T {
                return decode_mod.parseInto(T, Self, arena, src, options);
            }

            /// Reader-input variant of `parseInto`: drains the reader into arena
            /// memory, then parses and decodes.
            pub fn parseIntoReader(comptime T: type, arena: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) (ReaderError || DecodeError)!T {
                return decode_mod.parseIntoReader(T, Self, arena, reader, options);
            }

            /// Encode a typed Zig value as JSON, honoring the same `json_rename` /
            /// `json_skip` / `json_flatten` / `json_tag` / `json_payload` annotations
            /// and `toJson` hooks that `decode` honors, so the output decodes back
            /// through this codec's `parseInto`. Null optional fields are omitted
            /// entirely; enums emit their tag name as a string; tagged unions emit the
            /// discriminator member first, then either the payload's fields inline or,
            /// with `json_payload`, the payload under that member. `options.indent` pretty-prints
            /// and `options.sort_keys` emits members in ascending key order (declaration
            /// order otherwise). `arena` only backs `Value`s built by `toJson` hooks and
            /// the buffers `sort_keys` uses to reorder members.
            ///
            /// Each type's annotations and hooks come from this codec's entry for it
            /// where the entry's value is non-null, else from the type's own
            /// declarations.
            pub fn encodeTyped(w: *std.Io.Writer, value: anytype, arena: std.mem.Allocator, options: EncodeOptions) EncodeError!void {
                return encoder_mod.encodeTyped(Self, w, value, arena, options);
            }

            fn find(comptime T: type) ?Annotations(T) {
                return inline for (annotations) |annotation_entry| {
                    const TOption = @TypeOf(annotation_entry);
                    if (TOption.associated_type == T) break annotation_entry;
                } else null;
            }
        };

        @compileError("Type annotation should be exactly an Annotations(T) instance.");
    }
}

fn checkHooksNamespace(comptime T: type, comptime Hooks: type) void {
    comptime {
        const source = "Annotations(" ++ @typeName(T) ++ ").hooks";
        if (@typeInfo(T) != .@"struct") {
            @compileError(source ++ ": hooks apply to structs only, and " ++ @typeName(T) ++ " is not a struct");
        }
        if (@typeInfo(Hooks) != .@"struct") {
            @compileError(source ++ " must be a struct type declaring fromJson and/or toJson, got " ++ @typeName(Hooks));
        }
        for (@typeInfo(Hooks).@"struct".decls) |decl| {
            if (!std.mem.eql(u8, decl.name, "fromJson") and !std.mem.eql(u8, decl.name, "toJson")) {
                @compileError(source ++ " declares `" ++ decl.name ++ "`; its only pub declarations may be fromJson and toJson");
            }
        }
        if (@hasDecl(Hooks, "fromJson")) decode_mod.checkHook(T, Hooks, .fromJson);
        if (@hasDecl(Hooks, "toJson")) decode_mod.checkHook(T, Hooks, .toJson);
    }
}

/// Comptime branch budget for work that grows with the square of `n`, so a
/// large type never hits the default limit.
fn quadraticQuota(comptime n: usize) comptime_int {
    return 10_000 + 100 * n * n;
}

/// Sizes of `T` that set branch quotas, each computed once per type.
fn Budget(comptime T: type) type {
    return struct {
        /// Fields or variants of `T`, plus those of each field or variant type.
        const members: usize = count: switch (@typeInfo(T)) {
            inline .@"struct", .@"union" => |info| {
                @setEvalBranchQuota(1000 + 10 * info.fields.len);
                var n: usize = info.fields.len;
                for (info.fields) |f| {
                    switch (@typeInfo(f.type)) {
                        inline .@"struct", .@"union" => |inner| n += inner.fields.len,
                        else => {},
                    }
                }
                break :count n;
            },
            else => 0,
        };
    };
}

/// The entry `C` holds for `T`, or an all-null entry when it has none.
pub fn entryOf(comptime C: type, comptime T: type) Annotations(T) {
    // Every annotation lookup passes through here, adding comptime calls
    // per field over plain declarations; raise the branch limit so a type
    // that fits the default limit without a codec still compiles.
    @setEvalBranchQuota(quadraticQuota(Budget(T).members + C.annotations.len));
    return C.find(T) orelse .{};
}

test "codec: a json_rename entry renames a struct field on decode" {
    const GrantAbilityEffectDescriptor = struct {
        AbilityType: enum { AttackOverride, Strikethrough },
        Duration: enum { Permanent, EndOfTurn },
        AbilityValue: u8,
    };

    const _GrantAbilityEffectDescriptor: Annotations(GrantAbilityEffectDescriptor) = comptime .{
        .json_rename = &.{.{ .zig_name = "AbilityType", .json_name = "GrantableAbilityType" }},
    };
    const TestCodec = comptime Codec(.{_GrantAbilityEffectDescriptor});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();

    const src =
        \\{
        \\  "GrantableAbilityType":"Strikethrough",
        \\  "Duration":"EndOfTurn",
        \\  "AbilityValue":2
        \\}
    ;

    const c = try TestCodec.parseInto(GrantAbilityEffectDescriptor, ar.allocator(), src, .{});
    try std.testing.expectEqual(.Strikethrough, c.AbilityType);
    try std.testing.expectEqual(.EndOfTurn, c.Duration);
}

test "codec: json_skip and json_flatten entries apply on decode" {
    const C = struct {
        runtime: u32 = 7,
        common: struct { verbose: bool = false },
    };

    const _C: Annotations(C) = comptime .{
        .json_skip = &[_][]const u8{"runtime"},
        .json_flatten = &[_][]const u8{"common"},
    };
    const TestCodec = comptime Codec(.{_C});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();

    const c = try TestCodec.parseInto(C, ar.allocator(), "{\"verbose\":true}", .{});
    try std.testing.expectEqual(@as(u32, 7), c.runtime);
    try std.testing.expectEqual(true, c.common.verbose);
}

test "codec: a hooks fromJson replaces built-in decoding" {
    const SemVer = struct {
        major: u32,
        minor: u32,
        patch: u32,
    };

    const _SemVer: Annotations(SemVer) = comptime .{
        .hooks = struct {
            pub fn fromJson(arena: std.mem.Allocator, value: Value, _: parser_mod.ParseOptions) DecodeError!SemVer {
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
        },
    };
    const TestCodec = comptime Codec(.{_SemVer});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const C = struct { v: SemVer };
    const c = try TestCodec.parseInto(C, ar.allocator(), "{\"v\":\"1.2.3\"}", .{});
    try std.testing.expectEqual(@as(u32, 1), c.v.major);
    try std.testing.expectEqual(@as(u32, 2), c.v.minor);
    try std.testing.expectEqual(@as(u32, 3), c.v.patch);
}

test "codec: a union entry sets json_tag, json_payload, and variant renames" {
    const Flat = struct { BaseValue: u16 };
    const PersistentEffect = struct {
        fn PersistentEffect(comptime value: u8) type {
            return struct {
                Counters: struct {
                    IsPersistent: bool = true,
                    Counters: []struct {
                        SourceId: i8 = -1,
                        Duration: u8 = 0,
                        Value: u8 = value,
                    },
                },
            };
        }
    }.PersistentEffect;

    const Component = union(enum) {
        Aquatic: PersistentEffect(0),
        Armor: struct { ArmorAmount: Flat },
        Attack: struct { AttackValue: Flat },
        AttackOverride: PersistentEffect(2),
        AttacksInAllLanes: struct {},
        AttacksOnlyInAdjacentLanes: struct {},
        BoardAbility: struct {},
        Burst: struct {},
        Card: struct { Guid: i16 },
    };

    const _Component: Annotations(Component) = .{
        .json_tag = "$type",
        .json_payload = "$data",
        .json_rename = blk: {
            const renames = comptime inner: {
                const fields = @typeInfo(Component).@"union".fields;
                var renames: [fields.len]AnnotationRename = undefined;
                for (fields, 0..) |field, i| {
                    renames[i] = .{
                        .json_name = "Game.Components." ++ field.name,
                        .zig_name = field.name,
                    };
                }

                break :inner renames;
            };

            break :blk &renames;
        },
    };

    const TestCodec = Codec(.{_Component});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();

    const src =
        \\{
        \\  "$type":"Game.Components.AttackOverride",
        \\  "$data":{
        \\      "Counters":{
        \\          "IsPersistent":true,
        \\          "Counters":[
        \\              {
        \\                  "SourceId":-1,
        \\                  "Duration":0,
        \\                  "Value":2
        \\              }
        \\          ]
        \\      }
        \\  }
        \\}
    ;

    const c = try TestCodec.parseInto(Component, ar.allocator(), src, .{});
    try std.testing.expectEqual(true, c.AttackOverride.Counters.IsPersistent);
    try std.testing.expectEqual(@as(i8, -1), c.AttackOverride.Counters.Counters[0].SourceId);
    try std.testing.expectEqual(@as(u8, 2), c.AttackOverride.Counters.Counters[0].Value);
}

test "codec: a duplicate key with an invalid first value decodes last-wins" {
    const T = struct { a: u32, b: void = {} };
    const _T: Annotations(T) = .{ .json_skip = &[_][]const u8{"b"} };
    const TestCodec = Codec(.{_T});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const V = try TestCodec.parseInto(T, ar.allocator(), "{\"a\":\"not an int\",\"a\":7}", .{});
    try std.testing.expectEqual(@as(u32, 7), V.a);
}

test "codec: a hooks toJson replaces built-in encoding" {
    const SemVer = struct {
        major: u32,
        minor: u32,
        patch: u32,
    };
    const _SemVer: Annotations(SemVer) = comptime .{
        .hooks = struct {
            pub fn toJson(self: SemVer, arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
                const s = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
                return .{ .string = s };
            }
        },
    };
    const TestCodec = comptime Codec(.{_SemVer});

    const C = struct { v: SemVer };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .v = .{ .major = 1, .minor = 2, .patch = 3 } };
    try TestCodec.encodeTyped(&aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("{\"v\":\"1.2.3\"}", aw.written());
}

test "codec: sort_keys orders renamed keys, and the default keeps declaration order" {
    const C = struct { zebra: u8, apple: u8, mango: u8 };
    const _C: Annotations(C) = comptime .{ .json_rename = &.{.{ .zig_name = "zebra", .json_name = "zucchini" }} };
    const TestCodec = comptime Codec(.{_C});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .zebra = 1, .apple = 2, .mango = 3 };
    try TestCodec.encodeTyped(&aw.writer, c, a, .{ .sort_keys = true });
    try std.testing.expectEqualStrings("{\"apple\":2,\"mango\":3,\"zucchini\":1}", aw.written());

    aw.clearRetainingCapacity();
    try TestCodec.encodeTyped(&aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("{\"zucchini\":1,\"apple\":2,\"mango\":3}", aw.written());
}

test "codec: codec hooks override the type's own toJson" {
    const Euclidean = struct {
        quotient: u16,
        remainder: u16,

        pub fn toJson(self: @This(), arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
            _ = arena;
            return .{ .integer = self.quotient * 10 + self.remainder };
        }
    };
    const _Euclidean: Annotations(Euclidean) = comptime .{
        .json_rename = &.{.{ .zig_name = "quotient", .json_name = "quot" }},
        .hooks = struct {
            pub fn toJson(self: Euclidean, arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
                _ = arena;
                return .{ .integer = self.quotient * 100 + self.remainder };
            }
        },
    };
    const TestCodec = Codec(.{_Euclidean});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: Euclidean = .{ .quotient = 5, .remainder = 3 };
    try TestCodec.encodeTyped(&aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("503", aw.written());
}

test "codec: null hooks fall back to the type's own toJson" {
    const Euclidean = struct {
        quotient: u16,
        remainder: u16,

        pub fn toJson(self: @This(), arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
            _ = arena;
            return .{ .integer = self.quotient * 10 + self.remainder };
        }
    };
    const _Euclidean: Annotations(Euclidean) = comptime .{ .json_rename = &.{.{ .zig_name = "quotient", .json_name = "quot" }} };
    const TestCodec = Codec(.{_Euclidean});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: Euclidean = .{ .quotient = 5, .remainder = 3 };
    try TestCodec.encodeTyped(&aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("53", aw.written());
}

test "codec: empty hooks namespace clears the type's own toJson" {
    const Euclidean = struct {
        quotient: u16,
        remainder: u16,

        pub fn toJson(self: @This(), arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
            _ = arena;
            return .{ .integer = self.quotient * 10 + self.remainder };
        }
    };
    const _Euclidean: Annotations(Euclidean) = comptime .{
        .json_rename = &.{.{ .zig_name = "quotient", .json_name = "quot" }},
        .hooks = struct {},
    };
    const TestCodec = Codec(.{_Euclidean});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: Euclidean = .{ .quotient = 5, .remainder = 3 };
    try TestCodec.encodeTyped(&aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("{\"quot\":5,\"remainder\":3}", aw.written());
}

test "codec: a hooks namespace with only toJson decodes by reflection" {
    const Euclidean = struct {
        quotient: u16,
        remainder: u16,

        pub fn toJson(self: @This(), arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
            _ = arena;
            return .{ .integer = self.quotient * 10 + self.remainder };
        }
    };
    const _Euclidean: Annotations(Euclidean) = comptime .{
        .json_rename = &.{.{ .zig_name = "quotient", .json_name = "quot" }},
        .hooks = struct {
            pub fn toJson(self: Euclidean, arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
                _ = arena;
                return .{ .integer = self.quotient * 100 + self.remainder };
            }
        },
    };
    const TestCodec = Codec(.{_Euclidean});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: Euclidean = .{ .quotient = 5, .remainder = 3 };
    try TestCodec.encodeTyped(&aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("503", aw.written());

    const back = try TestCodec.parseInto(Euclidean, a, "{\"quot\":5,\"remainder\":3}", .{});
    try std.testing.expectEqual(c, back);
}

fn encodeAlloc(comptime C: type, a: Allocator, value: anytype, options: EncodeOptions) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try C.encodeTyped(&aw.writer, value, a, options);
    return aw.written();
}

/// Encodes `value` through `C`, expects `expected`, and decodes it back
/// through `C` to `decoded` (the value with skipped fields at defaults).
fn expectRoundTrip(comptime C: type, comptime T: type, a: Allocator, value: T, expected: []const u8, decoded: T) !void {
    const out = try encodeAlloc(C, a, value, .{});
    try std.testing.expectEqualStrings(expected, out);
    try std.testing.expectEqualDeep(decoded, try C.parseInto(T, a, out, .{}));
    const sorted = try encodeAlloc(C, a, value, .{ .sort_keys = true, .indent = 2 });
    try std.testing.expectEqualDeep(decoded, try C.parseInto(T, a, sorted, .{}));
}

test "codec: json_rename override, null fallback, and empty-list clear" {
    const T = struct {
        pub const json_rename = .{ .a = "A", .b = "B" };
        a: u8,
        b: u8,
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v: T = .{ .a = 1, .b = 2 };

    const Override = Codec(.{Annotations(T){ .json_rename = &.{.{ .zig_name = "a", .json_name = "x" }} }});
    try expectRoundTrip(Override, T, a, v, "{\"x\":1,\"b\":2}", v);
    const Fallback = Codec(.{Annotations(T){ .json_skip = &.{} }});
    try expectRoundTrip(Fallback, T, a, v, "{\"A\":1,\"B\":2}", v);
    const Clear = Codec(.{Annotations(T){ .json_rename = &.{} }});
    try expectRoundTrip(Clear, T, a, v, "{\"a\":1,\"b\":2}", v);
}

test "codec: json_skip override, null fallback, and empty-list clear" {
    const T = struct {
        pub const json_skip = .{"a"};
        a: u8 = 7,
        b: u8 = 8,
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v: T = .{ .a = 1, .b = 2 };

    const Override = Codec(.{Annotations(T){ .json_skip = &.{"b"} }});
    try expectRoundTrip(Override, T, a, v, "{\"a\":1}", .{ .a = 1, .b = 8 });
    const Fallback = Codec(.{Annotations(T){ .json_rename = &.{} }});
    try expectRoundTrip(Fallback, T, a, v, "{\"b\":2}", .{ .a = 7, .b = 2 });
    const Clear = Codec(.{Annotations(T){ .json_skip = &.{} }});
    try expectRoundTrip(Clear, T, a, v, "{\"a\":1,\"b\":2}", v);
}

test "codec: json_flatten override, null fallback, and empty-list clear" {
    const Inner = struct { x: u8 };
    const T = struct {
        pub const json_flatten = .{"i"};
        i: Inner,
        j: Inner,
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v: T = .{ .i = .{ .x = 1 }, .j = .{ .x = 2 } };

    const Override = Codec(.{Annotations(T){ .json_flatten = &.{"j"} }});
    try expectRoundTrip(Override, T, a, v, "{\"i\":{\"x\":1},\"x\":2}", v);
    const Fallback = Codec(.{Annotations(T){ .json_skip = &.{} }});
    try expectRoundTrip(Fallback, T, a, v, "{\"x\":1,\"j\":{\"x\":2}}", v);
    const Clear = Codec(.{Annotations(T){ .json_flatten = &.{} }});
    try expectRoundTrip(Clear, T, a, v, "{\"i\":{\"x\":1},\"j\":{\"x\":2}}", v);
}

test "codec: json_tag override and null fallback" {
    const U = union(enum) {
        pub const json_tag = "kind";
        a: struct { n: u8 },
        b: void,
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const Override = Codec(.{Annotations(U){ .json_tag = "type" }});
    try expectRoundTrip(Override, U, a, .{ .a = .{ .n = 1 } }, "{\"type\":\"a\",\"n\":1}", .{ .a = .{ .n = 1 } });
    const Fallback = Codec(.{Annotations(U){ .json_rename = &.{.{ .zig_name = "b", .json_name = "B" }} }});
    try expectRoundTrip(Fallback, U, a, .{ .a = .{ .n = 1 } }, "{\"kind\":\"a\",\"n\":1}", .{ .a = .{ .n = 1 } });
    try expectRoundTrip(Fallback, U, a, .b, "{\"kind\":\"B\"}", .b);
}

test "codec: json_payload override and null fallback" {
    const U = union(enum) {
        pub const json_tag = "kind";
        pub const json_payload = "value";
        a: struct { n: u8 },
        b: void,
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v: U = .{ .a = .{ .n = 1 } };

    const Override = Codec(.{Annotations(U){ .json_payload = "data" }});
    try expectRoundTrip(Override, U, a, v, "{\"kind\":\"a\",\"data\":{\"n\":1}}", v);
    const Fallback = Codec(.{Annotations(U){ .json_tag = "type" }});
    try expectRoundTrip(Fallback, U, a, v, "{\"type\":\"a\",\"value\":{\"n\":1}}", v);
}

test "codec: hooks replace both of the type's hooks, clear them, or keep one explicitly" {
    const V = struct {
        major: u8,
        minor: u8,

        pub fn fromJson(_: Allocator, value: Value, _: ParseOptions) DecodeError!@This() {
            if (value != .string or value.string.len != 3) return error.TypeMismatch;
            return .{ .major = value.string[0] - '0', .minor = value.string[2] - '0' };
        }

        pub fn toJson(self: @This(), arena: Allocator) Allocator.Error!Value {
            return .{ .string = try std.fmt.allocPrint(arena, "{d}.{d}", .{ self.major, self.minor }) };
        }
    };
    const AsInt = struct {
        pub fn fromJson(_: Allocator, value: Value, _: ParseOptions) DecodeError!V {
            if (value != .integer) return error.TypeMismatch;
            return .{ .major = @intCast(@divTrunc(value.integer, 100)), .minor = @intCast(@mod(value.integer, 100)) };
        }

        pub fn toJson(self: V, _: Allocator) Allocator.Error!Value {
            return .{ .integer = @as(i128, self.major) * 100 + self.minor };
        }
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v: V = .{ .major = 1, .minor = 2 };

    const Own = Codec(.{Annotations(V){ .json_rename = &.{} }});
    try expectRoundTrip(Own, V, a, v, "\"1.2\"", v);

    const Pair = Codec(.{Annotations(V){ .hooks = AsInt }});
    try expectRoundTrip(Pair, V, a, v, "102", v);

    const Cleared = Codec(.{Annotations(V){ .hooks = struct {} }});
    try expectRoundTrip(Cleared, V, a, v, "{\"major\":1,\"minor\":2}", v);

    const DecodeOnly = Codec(.{Annotations(V){ .hooks = struct {
        pub const fromJson = AsInt.fromJson;
    } }});
    try std.testing.expectEqualStrings("{\"major\":1,\"minor\":2}", try encodeAlloc(DecodeOnly, a, v, .{}));
    try std.testing.expectEqual(v, try DecodeOnly.parseInto(V, a, "102", .{}));

    const KeepOwnDecode = Codec(.{Annotations(V){ .hooks = struct {
        pub const fromJson = V.fromJson;
        pub const toJson = AsInt.toJson;
    } }});
    try std.testing.expectEqualStrings("102", try encodeAlloc(KeepOwnDecode, a, v, .{}));
    try std.testing.expectEqual(v, try KeepOwnDecode.parseInto(V, a, "\"1.2\"", .{}));
}

test "codec: entries apply wherever the type appears" {
    const Leaf = struct { a: u8 };
    const T = struct {
        one: Leaf,
        maybe: ?Leaf,
        many: []const Leaf,
        fixed: [1]Leaf,
    };
    const C = Codec(.{Annotations(Leaf){ .json_rename = &.{.{ .zig_name = "a", .json_name = "A" }} }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v: T = .{ .one = .{ .a = 1 }, .maybe = .{ .a = 2 }, .many = &.{.{ .a = 3 }}, .fixed = .{.{ .a = 4 }} };
    try expectRoundTrip(C, T, a, v, "{\"one\":{\"A\":1},\"maybe\":{\"A\":2},\"many\":[{\"A\":3}],\"fixed\":[{\"A\":4}]}", v);
}

test "codec: decode and parseIntoReader honor entries" {
    const T = struct { a: u8, b: []const u8 };
    const C = Codec(.{Annotations(T){ .json_rename = &.{.{ .zig_name = "a", .json_name = "A" }} }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{\"A\":1,\"b\":\"x\"}";

    const tree = try parser_mod.parse(a, src, .{});
    const from_tree = try C.decode(T, a, tree, .{});
    try std.testing.expectEqual(@as(u8, 1), from_tree.a);
    try std.testing.expectEqualStrings("x", from_tree.b);

    var reader: std.Io.Reader = .fixed(src);
    const from_reader = try C.parseIntoReader(T, a, &reader, .{});
    try std.testing.expectEqualDeep(from_tree, from_reader);

    var bad: std.Io.Reader = .fixed("{\"a\":1,\"b\":\"x\"}");
    try std.testing.expectError(error.UnknownField, C.parseIntoReader(T, a, &bad, .{}));
}

test "codec: streaming and tree decoding agree under a codec rename" {
    const T = struct { a: u8, b: ?u8 = null, c: u8 = 9 };
    const C = Codec(.{Annotations(T){ .json_rename = &.{ .{ .zig_name = "a", .json_name = "A" }, .{ .zig_name = "c", .json_name = "a" } } }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const inputs = [_][]const u8{
        "{\"A\":1}",
        "{\"A\":1,\"b\":2,\"a\":3}",
        "{\"a\":3,\"A\":1}",
        "{\"A\":1,\"c\":3}",
        "{\"b\":2}",
        "{\"A\":\"x\"}",
        "{\"A\":300}",
    };
    for (inputs) |src| {
        const streamed = C.parseInto(T, a, src, .{});
        const tree = C.decode(T, a, try parser_mod.parse(a, src, .{}), .{});
        if (tree) |want| {
            try std.testing.expectEqual(want, try streamed);
        } else |want_err| {
            try std.testing.expectError(want_err, streamed);
        }
    }
}

test "codec: generic hooks work type-local and aliased through a namespace" {
    const G = struct {
        n: u8,

        pub fn fromJson(_: anytype, value: Value, _: anytype) DecodeError!@This() {
            if (value != .integer) return error.TypeMismatch;
            return .{ .n = @intCast(value.integer) };
        }

        pub fn toJson(self: anytype, _: Allocator) Allocator.Error!Value {
            return .{ .integer = self.n };
        }
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v: G = .{ .n = 5 };

    try expectRoundTrip(Codec(.{}), G, a, v, "5", v);
    const Aliased = Codec(.{Annotations(G){ .hooks = struct {
        pub const fromJson = G.fromJson;
        pub const toJson = G.toJson;
    } }});
    try expectRoundTrip(Aliased, G, a, v, "5", v);
}

test "codec: hook signatures accept a bare return type, a narrower error set, and private helpers" {
    const P = struct { n: u8 };
    const C = Codec(.{Annotations(P){ .hooks = struct {
        fn digit(n: u8) u8 {
            return n % 10;
        }

        pub fn fromJson(_: Allocator, _: Value, _: ParseOptions) P {
            return .{ .n = digit(17) };
        }

        pub fn toJson(self: P, _: Allocator) error{OutOfMemory}!Value {
            return .{ .integer = self.n };
        }
    } }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectEqualStrings("3", try encodeAlloc(C, a, P{ .n = 3 }, .{}));
    try std.testing.expectEqual(P{ .n = 7 }, try C.parseInto(P, a, "0", .{}));
}

test "codec: a config with dozens of nested fields compiles with and without codec entries" {
    const Config = struct {
        name: []const u8,
        version: []const u8,
        debug: bool,
        max_connections: u32,
        timeout_ms: f64,
        tags: []const []const u8,
        server: struct {
            host: []const u8,
            port: u16,
            tls: struct {
                enabled: bool,
                cert_path: []const u8,
                key_path: []const u8,
                min_version: []const u8,
            },
        },
        upstream: struct {
            endpoints: []const []const u8,
            retry: struct {
                max_attempts: u32,
                backoff_base_ms: u32,
                backoff_factor: f64,
                jitter: bool,
            },
        },
        limits: struct {
            queue_depth: u32,
            batch_size: u32,
            flush_interval_ms: u32,
            max_payload_bytes: u64,
            drop_on_overflow: bool,
        },
        log: struct {
            level: []const u8,
            format: []const u8,
            path: []const u8,
            rotate_mb: u32,
        },
        features: struct {
            compression: []const u8,
            dedupe: bool,
            sampling_rate: f64,
            histogram_buckets: []const f64,
        },
    };
    const src =
        \\{"name":"n","version":"1","debug":false,"max_connections":8,"timeout_ms":1.5,"tags":["a"],
        \\"server":{"host":"h","port":1,"tls":{"enabled":true,"cert_path":"c","key_path":"k","min_version":"1.2"}},
        \\"upstream":{"endpoints":["e"],"retry":{"max_attempts":3,"backoff_base_ms":10,"backoff_factor":2,"jitter":true}},
        \\"limits":{"queue_depth":1,"batch_size":2,"flush_interval_ms":3,"max_payload_bytes":4,"drop_on_overflow":false},
        \\"log":{"level":"info","format":"json","path":"p","rotate_mb":5},
        \\"features":{"compression":"zstd","dedupe":true,"sampling_rate":0.5,"histogram_buckets":[1,2]}}
    ;
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const plain = try decode_mod.parseInto(Config, Codec(.{}), a, src, .{});
    try std.testing.expectEqual(@as(u16, 1), plain.server.port);
    const Server = @FieldType(Config, "server");
    const C = Codec(.{Annotations(Server){ .json_rename = &.{} }});
    const coded = try C.parseInto(Config, a, src, .{});
    try std.testing.expectEqualDeep(plain, coded);
    try std.testing.expectEqualDeep(plain, try C.parseInto(Config, a, try encodeAlloc(C, a, coded, .{}), .{}));
}
