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
const v = @import("value.zig");

const Allocator = std.mem.Allocator;
const Error = parser_mod.Error;
const ParseOptions = parser_mod.ParseOptions;
const EncodeOptions = encoder_mod.EncodeOptions;
const ReaderError = parser_mod.ReaderError;
const DecodeError = decode_mod.DecodeError;
const EncodeError = encoder_mod.EncodeError;
const Value = v.Value;

/// JSON name override.
/// Reasoning: variable-length tuples are not present in Zig,
/// therefore, this is used with comptime-generated and external types.
pub const AnnotationRename = struct {
    json_name: []const u8,
    zig_name: []const u8,
};

/// Type's external annotation record.
/// Provides JSON parsing hooks for typed decoding and encoding.
pub fn Annotations(comptime T: type) type {
    return struct {
        /// Type this annotates.
        pub const associated_type: type = T;

        /// Field name overrides.
        json_rename: ?[]const AnnotationRename = null,
        /// Fields with subfields that will be decoded from the parent object.
        json_flatten: ?[]const []const u8 = null,
        /// Fields excluded from decode/encode.
        json_skip: ?[]const []const u8 = null,

        /// Custom deserialization of `T` struct.
        fromJson: ?*const fn (arena: Allocator, value: Value, options: ParseOptions) DecodeError!T = null,
        /// Custom serialization of `T` struct.
        toJson: ?*const fn (self: T, arena: Allocator) Allocator.Error!Value = null,

        /// Discriminator member for tagged unions.
        json_tag: ?[]const u8 = null,
        // Payload / value member for tagged unions.
        json_payload: ?[]const u8 = null,
    };
}

/// Defines precedence rules for annotations.
pub const AnnotationsSource = enum {
    /// Use only annotations provided by the supplied codec.
    codec_only,
    /// Use codec entries when possible, fall back to local annotations.
    codec_then_local,
    /// Use local type annotations, fall back to codec entries.
    local_then_codec,
    /// Use only local annotations.
    /// Prefer using other options and passing an empty codec.
    local_only,
};

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
//         .{ .json_name = "special_abilities", .zig_name = "abilities" },
//         .{ .json_name = "extra_tags", .zig_name = "tags" },
//     },
//     .json_skip = &[_][]const u8{ ... },
// };
// const _Component: json.Annotations(Component) = .{ .json_tag = "$type" };
// const _EffectEntityComponent: json.Annotations(EffectEntityComponent) = .{ .json_tag = "$type" };
// const _Query: json.Annotations(Query) = .{
//     .json_tag = "$type",
//     .json_rename = &.{
//         .{ .json_name = "AlwaysMatchesQuery", .zig_name = "AlwaysMatches" },
//     },
// };
// pub const ComponentUnionRegistry = json.Codec(.{ _CardDescriptor, _Component, ..., _Query });
// ```
pub fn TypedCodec(comptime type_options: anytype) type {
    comptime {
        for (type_options, 0..) |annotation, i| {
            const TOption = @TypeOf(annotation);
            if (!@hasDecl(TOption, "associated_type")) break;

            const T = TOption.associated_type;
            if (TOption != Annotations(T)) break;

            for (0..i) |j| {
                const TPrev = @TypeOf(type_options[j]);
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

            if (@typeInfo(T) == .@"union" and
                annotation.json_tag != null and
                annotation.json_payload != null and
                std.mem.eql(u8, annotation.json_tag.?, annotation.json_payload.?))
            {
                @compileError("json_tag and json_payload collision - cannot share the field name.");
            }
        } else return struct {
            const annotations = type_options;
            const Self = @This();

            /// Decode a parsed `Value` tree into `T` via comptime reflection.
            /// Supports bool, ints (overflow-checked), floats, `[]const u8`,
            /// slices, fixed-size arrays, optionals, nested structs, enums (string
            /// name or integer tag), tagged unions via `json_tag`, embedded `Value`
            /// fields (kept dynamic), custom `fromJson` hooks, and the
            /// `json_rename` / `json_skip` / `json_flatten` annotations from this codec.
            ///
            /// Number policy: float targets accept `.integer` values, but integer
            /// targets do NOT accept `.float` -- `1e2` parses as `.float` and stays
            /// one. In typed mode, integer literals in the range [minInt(i128),
            /// maxInt(i128)] decode into any integer target that fits (overflow
            /// returns `error.Overflow`). For u128 or literals beyond i128 range,
            /// use `number_mode = .raw` so the lexeme decodes directly into the
            /// target. JSON `null` decodes only into optional targets; anywhere else
            /// it errors like an absent field. See `src/decode.zig`.
            pub fn decode(comptime T: type, comptime codec_priority: AnnotationsSource, arena: std.mem.Allocator, value: Value, options: ParseOptions) DecodeError!T {
                return decode_mod.decode(T, Self, codec_priority, arena, value, options);
            }

            /// Decode `src` directly into a `T` using hooks from this `TypedCodec`.
            /// Types without `Value` fields, `fromJson` hooks, or tagged unions decode in
            /// a single streaming pass with no intermediate `Value` tree; other types
            /// (and calls requesting `options.spans`) parse to a tree first. Both paths
            /// accept and reject identically. All allocations land in `arena`; string
            /// fields may be zero-copy slices into `src`, so keep `src` alive while the
            /// result is in use.
            pub fn parseInto(comptime T: type, comptime codec_priority: AnnotationsSource, arena: std.mem.Allocator, src: []const u8, options: ParseOptions) (Error || DecodeError)!T {
                return decode_mod.parseInto(T, Self, codec_priority, arena, src, options);
            }

            /// Reader-input variant of `parseInto`: drains the reader into arena
            /// memory, then parses and decodes.
            pub fn parseIntoReader(comptime T: type, comptime codec_priority: AnnotationsSource, arena: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) (ReaderError || DecodeError)!T {
                return decode_mod.parseIntoReader(T, Self, codec_priority, arena, reader, options);
            }

            /// Encode a typed Zig value as JSON, honoring the same `json_rename` /
            /// `json_skip` / `json_flatten` / `json_tag` annotations and `toJson` hooks
            /// that `decode` honors, so the output decodes back via `parseInto(T, ...)`.
            /// Null optional fields are omitted entirely; enums emit their tag name as a
            /// string; tagged unions emit the discriminator member first with the
            /// payload's fields inline in the same object. `options.indent` pretty-prints
            /// and `options.sort_keys` emits members in ascending key order (declaration
            /// order otherwise). `arena` only backs `Value`s built by `toJson` hooks and
            /// the buffers `sort_keys` uses to reorder members.
            ///
            /// Annotations and hooks are read from `Annotations(T)` and `@TypeOf(value)`.
            pub fn encode(comptime codec_priority: AnnotationsSource, w: *std.Io.Writer, value: anytype, arena: std.mem.Allocator, options: EncodeOptions) EncodeError!void {
                return encoder_mod.encodeTyped(Self, codec_priority, w, value, arena, options);
            }

            /// Determines whether an entry for `T` exists in this `Codec`.
            pub fn has(comptime T: type) bool {
                return inline for (annotations) |annotation_entry| {
                    const TOption = @TypeOf(annotation_entry);
                    if (TOption.associated_type == T) break true;
                } else false;
            }

            /// Retrieves entry for `T` in this `Codec`.
            pub fn get(comptime T: type) Annotations(T) {
                inline for (annotations) |annotation_entry| {
                    const TOption = @TypeOf(annotation_entry);
                    if (TOption.associated_type == T) return annotation_entry;
                } else @compileError("Codec lacks entry for " ++ @typeName(T) ++ ".");
            }

            /// Retrieves entry for `T` in this `Codec`, if exists.
            pub fn getOrEmpty(comptime T: type) ?Annotations(T) {
                return inline for (annotations) |annotation_entry| {
                    const TOption = @TypeOf(annotation_entry);
                    if (TOption.associated_type == T) break annotation_entry;
                } else null;
            }
        };

        @compileError("Type annotation should be exactly an Annotations(T) instance.");
    }
}

test "codec: decode struct json_rename" {
    const GrantAbilityEffectDescriptor = struct {
        AbilityType: enum { AttackOverride, Strikethrough },
        Duration: enum { Permanent, EndOfTurn },
        AbilityValue: u8,
    };

    const _GrantAbilityEffectDescriptor: Annotations(GrantAbilityEffectDescriptor) = comptime .{
        .json_rename = &.{.{ .json_name = "GrantableAbilityType", .zig_name = "AbilityType" }},
    };
    const Codec = comptime TypedCodec(.{_GrantAbilityEffectDescriptor});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();

    const src =
        \\{
        \\  "GrantableAbilityType":"Strikethrough",
        \\  "Duration":"EndOfTurn",
        \\  "AbilityValue":2
        \\}
    ;

    const c = try Codec.parseInto(GrantAbilityEffectDescriptor, .codec_then_local, ar.allocator(), src, .{});
    try std.testing.expectEqual(.Strikethrough, c.AbilityType);
    try std.testing.expectEqual(.EndOfTurn, c.Duration);
}

test "codec: decode struct json_skip json_flatten" {
    const C = struct {
        runtime: u32 = 7,
        common: struct { verbose: bool = false },
    };

    const _C: Annotations(C) = comptime .{
        .json_skip = &[_][]const u8{"runtime"},
        .json_flatten = &[_][]const u8{"common"},
    };
    const Codec = comptime TypedCodec(.{_C});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();

    const c = try Codec.parseInto(C, .local_then_codec, ar.allocator(), "{\"verbose\":true}", .{});
    try std.testing.expectEqual(@as(u32, 7), c.runtime);
    try std.testing.expectEqual(true, c.common.verbose);
}

test "codec: decode struct fromJson mirrors decode fromJson hook short-circuits built-in dispatch" {
    const SemVer = struct {
        major: u32,
        minor: u32,
        patch: u32,
    };

    const _SemVer: Annotations(SemVer) = comptime .{
        .fromJson = struct {
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
        }.fromJson,
    };
    const Codec = comptime TypedCodec(.{_SemVer});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const C = struct { v: SemVer };
    const c = try Codec.parseInto(C, .codec_then_local, ar.allocator(), "{\"v\":\"1.2.3\"}", .{});
    try std.testing.expectEqual(@as(u32, 1), c.v.major);
    try std.testing.expectEqual(@as(u32, 2), c.v.minor);
    try std.testing.expectEqual(@as(u32, 3), c.v.patch);
}

test "codec: decode union json_tag json_payload json_rename" {
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
                        .json_name = "PvZCards.Engine.Components." ++ field.name ++ ", EngineLib, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null",
                        .zig_name = field.name,
                    };
                }

                break :inner renames;
            };

            break :blk &renames;
        },
    };

    const Codec = TypedCodec(.{_Component});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();

    const src =
        \\{
        \\  "$type":"PvZCards.Engine.Components.AttackOverride, EngineLib, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null",
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

    const c = try Codec.parseInto(Component, .codec_then_local, ar.allocator(), src, .{});
    try std.testing.expectEqual(true, c.AttackOverride.Counters.IsPersistent);
    try std.testing.expectEqual(@as(i8, -1), c.AttackOverride.Counters.Counters[0].SourceId);
    try std.testing.expectEqual(@as(u8, 2), c.AttackOverride.Counters.Counters[0].Value);
}

test "codec: streaming equivalence mirrors streaming equivalence: duplicate key with invalid first occurrence decodes last-wins" {
    const T = struct { a: u32, b: void = {} };
    const _T: Annotations(T) = .{ .json_skip = &[_][]const u8{"b"} };
    const Codec = TypedCodec(.{_T});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const V = try Codec.parseInto(T, .local_then_codec, ar.allocator(), "{\"a\":\"not an int\",\"a\":7}", .{});
    try std.testing.expectEqual(@as(u32, 7), V.a);
}

test "codec: encode struct toJson hook mirrors encodeTyped toJson hook overrides built-in encoding" {
    const SemVer = struct {
        major: u32,
        minor: u32,
        patch: u32,
    };
    const _SemVer: Annotations(SemVer) = comptime .{
        .toJson = struct {
            pub fn toJson(self: SemVer, arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
                const s = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
                return .{ .string = s };
            }
        }.toJson,
    };
    const Codec = comptime TypedCodec(.{_SemVer});

    const C = struct { v: SemVer };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .v = .{ .major = 1, .minor = 2, .patch = 3 } };
    try Codec.encode(.codec_then_local, &aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("{\"v\":\"1.2.3\"}", aw.written());
}

test "codec: encode sorted mirrors sort_keys: typed struct fields in key order, default keeps declaration" {
    const C = struct { zebra: u8, apple: u8, mango: u8 };
    const _C: Annotations(C) = comptime .{ .json_rename = &.{.{ .zig_name = "zebra", .json_name = "zucchini" }} };
    const Codec = comptime TypedCodec(.{_C});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .zebra = 1, .apple = 2, .mango = 3 };
    try Codec.encode(.local_then_codec, &aw.writer, c, a, .{ .sort_keys = true });
    try std.testing.expectEqualStrings("{\"apple\":2,\"mango\":3,\"zucchini\":1}", aw.written());

    aw.clearRetainingCapacity();
    try Codec.encode(.local_then_codec, &aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("{\"zucchini\":1,\"apple\":2,\"mango\":3}", aw.written());
}

test "codec: codec overrides local" {
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
        .toJson = struct {
            pub fn toJson(self: Euclidean, arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
                _ = arena;
                return .{ .integer = self.quotient * 100 + self.remainder };
            }
        }.toJson,
    };
    const Codec = TypedCodec(.{_Euclidean});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: Euclidean = .{ .quotient = 5, .remainder = 3 };
    try Codec.encode(.codec_then_local, &aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("503", aw.written());
}

test "codec: fallback from codec to local" {
    const Euclidean = struct {
        quotient: u16,
        remainder: u16,

        pub fn toJson(self: @This(), arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
            _ = arena;
            return .{ .integer = self.quotient * 10 + self.remainder };
        }
    };
    const _Euclidean: Annotations(Euclidean) = comptime .{ .json_rename = &.{.{ .zig_name = "quotient", .json_name = "quot" }} };
    const Codec = TypedCodec(.{_Euclidean});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: Euclidean = .{ .quotient = 5, .remainder = 3 };
    try Codec.encode(.codec_then_local, &aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("53", aw.written());
}

test "codec: no fallback from codec to local" {
    const Euclidean = struct {
        quotient: u16,
        remainder: u16,

        pub fn toJson(self: @This(), arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
            _ = arena;
            return .{ .integer = self.quotient * 10 + self.remainder };
        }
    };
    const _Euclidean: Annotations(Euclidean) = comptime .{ .json_rename = &.{.{ .zig_name = "quotient", .json_name = "quot" }} };
    const Codec = TypedCodec(.{_Euclidean});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: Euclidean = .{ .quotient = 5, .remainder = 3 };
    try Codec.encode(.codec_only, &aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("{\"quot\":5,\"remainder\":3}", aw.written());
}

test "codec: fallback from local to codec" {
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
        .toJson = struct {
            pub fn toJson(self: Euclidean, arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
                _ = arena;
                return .{ .integer = self.quotient * 100 + self.remainder };
            }
        }.toJson,
    };
    const Codec = TypedCodec(.{_Euclidean});

    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: Euclidean = .{ .quotient = 5, .remainder = 3 };
    try Codec.encode(.local_then_codec, &aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("53", aw.written());
}
