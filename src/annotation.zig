//! Type annotation utilities for typed encoding and decoding.
//!
//! Reasoning:
//! 1. Adding metadata to types from other packages;
//! 2. Support comptime-generated types from @Struct and @Union, where
//! embedding annotations by declaring fields is currently impossible /
//! undesirable behavior;
//! 3. Allow to overwrite default annotations for specific files when needed.

const std = @import("std");
const decode = @import("decode.zig");
const parser = @import("parser.zig");
const v = @import("value.zig");

const Allocator = std.mem.Allocator;
const DecodeError = decode.DecodeError;
const ParseOptions = parser.ParseOptions;
const Value = v.Value;

/// Provides JSON tags and parsing hooks for typed decoding.
/// Currently supports structs and tagged unions.
pub fn TypeAnnotationProvider(comptime T: type) type {
    return struct {
        /// Type this provider annotates.
        pub const associated_type: type = T;

        /// Name overrides.
        json_rename: ?type = null,
        /// Sub-fields are decoded from the parent object
        json_flatten: ?[]const []const u8 = null,
        /// Excluded from decode/encode.
        json_skip: ?[]const []const u8 = null,
        /// Custom deserialization of T,
        fromJson: ?*const fn (arena: Allocator, value: Value, options: ParseOptions) DecodeError!T = null,
        /// Custom serialization of T,
        toJson: ?*const fn (self: T, arena: Allocator) Allocator.Error!Value = null,
        /// Discriminator member for tagged unions,
        json_tag: ?[]const u8 = null,
    };
}

/// Default, empty type annotation registry.
/// Types are decoded using only their own declarations.
pub const DefaultTypes = TypeAnnotationOptions(.{});

/// Constructs annotation options for typed encoding and decoding.
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
// const _CardDescriptor: json.TypeAnnotationProvider(card_descriptor.CardDescriptor) = .{
//     .json_rename = struct {
//         pub const abilities = "special_abilities";
//         pub const extra_tags = "tags";
//     },
//     .json_skip = &[_][]const u8{ ... },
//     };
// const _Component: json.TypeAnnotationProvider(Component) = .{ .json_tag = "$type" };
// const _EffectEntityComponent: json.TypeAnnotationProvider(EffectEntityComponent) = .{ .json_tag = "$type" };
// const _Query: json.TypeAnnotationProvider(Query) = .{
//     .json_tag = "$type",
//     .json_rename = struct {
//         pub const AlwaysMatches = "AlwaysMatchesQuery";
//     },
// };
// pub const ComponentUnionRegistry = json.TypeAnnotationOptions(.{ _CardDescriptor, _Component, ..., _Query });
// ```
pub fn TypeAnnotationOptions(comptime options: anytype) type {
    comptime {
        for (options) |annotation_entry| {
            const TOption = @TypeOf(annotation_entry);
            if (!@hasDecl(TOption, "associated_type")) break;
            if (!@hasField(TOption, "json_rename")) break;
            if (!@hasField(TOption, "json_flatten")) break;
            if (!@hasField(TOption, "json_skip")) break;
            if (!@hasField(TOption, "fromJson")) break;
            if (!@hasField(TOption, "toJson")) break;
            if (!@hasField(TOption, "json_tag")) break;

            const T = TOption.associated_type;
            const kind = if (@typeInfo(T) == .@"union") "variant" else "field";
            if (annotation_entry.json_rename) |rename| {
                for (@typeInfo(rename).@"struct".fields) |rf| {
                    if (!@hasField(T, rf.name)) {
                        @compileError("json_rename entry `" ++ rf.name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                    }
                }
            }
            if (annotation_entry.json_skip) |skip| {
                for (skip) |name| {
                    if (!@hasField(T, name)) {
                        @compileError("json_skip entry `" ++ name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                    }
                }
            }
            if (annotation_entry.json_flatten) |flatten| {
                for (flatten) |name| {
                    if (!@hasField(T, name)) {
                        @compileError("json_flatten entry `" ++ name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                    }
                }
            }
        } else return struct {
            const annotation = options;

            /// Determines whether an entry for T exists.
            pub fn has(comptime T: type) bool {
                return inline for (annotation) |annotation_entry| {
                    const TOption = @TypeOf(annotation_entry);
                    if (TOption.associated_type == T) break true;
                } else false;
            }

            /// Retrieves entry for T.
            pub fn get(comptime T: type) TypeAnnotationProvider(T) {
                inline for (annotation) |annotation_entry| {
                    const TOption = @TypeOf(annotation_entry);
                    if (TOption.associated_type == T) return annotation_entry;
                } else @compileError("Annotation registry lacks entry for " ++ T ++ ".");
            }

            pub fn getOrEmpty(comptime T: type) ?TypeAnnotationProvider(T) {
                return inline for (annotation) |annotation_entry| {
                    const TOption = @TypeOf(annotation_entry);
                    if (TOption.associated_type == T) break annotation_entry;
                } else null;
            }
        };

        @compileError("Type annotation should be exactly a TypeAnnotationProvider(T) instance.");
    }
}
