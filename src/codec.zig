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
        for (0..entries.len) |i| checkEntry(entries, i);
    }
    return struct {
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
}

fn label(comptime i: usize, comptime T: type) []const u8 {
    return std.fmt.comptimePrint("Codec entry {d}, Annotations({s})", .{ i, @typeName(T) });
}

fn isKeyed(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => T != Value,
        else => false,
    };
}

fn checkNamesExist(comptime i: usize, comptime T: type, comptime prop: []const u8, comptime names: anytype) void {
    comptime {
        const kind = if (@typeInfo(T) == .@"union") "variant" else "field";
        for (names) |name| {
            if (!@hasField(T, name)) {
                @compileError(label(i, T) ++ "." ++ prop ++ ": `" ++ name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
            }
        }
    }
}

/// Construction-time checks of `entries[i]` on its own.
fn checkEntry(comptime entries: anytype, comptime i: usize) void {
    comptime {
        const E = @TypeOf(entries[i]);
        if (@typeInfo(E) != .@"struct" or !@hasDecl(E, "associated_type") or E != Annotations(E.associated_type)) {
            @compileError(std.fmt.comptimePrint("Codec entry {d} has type {s}; each entry must be an Annotations(T) value", .{ i, @typeName(E) }));
        }
        const T = E.associated_type;
        const entry: E = entries[i];
        const rename_count = if (entry.json_rename) |r| r.len else 0;
        @setEvalBranchQuota(quadraticQuota(Budget(T).members + rename_count + entries.len));
        for (0..i) |j| {
            if (@TypeOf(entries[j]) == E) {
                @compileError(std.fmt.comptimePrint("Codec entries {d} and {d} both annotate {s}; give each type one Annotations(T) entry", .{ j, i, @typeName(T) }));
            }
        }
        if (T == Value) {
            @compileError(label(i, T) ++ ": json.Value cannot be annotated; codec entries annotate structs and tagged unions");
        }
        if (!isKeyed(T)) {
            @compileError(label(i, T) ++ ": " ++ @typeName(T) ++ " is not a struct or union; codec entries annotate structs and tagged unions");
        }
        const is_union = @typeInfo(T) == .@"union";

        if (entry.json_rename) |renames| {
            for (renames, 0..) |r, k| {
                checkNamesExist(i, T, "json_rename", .{r.zig_name});
                for (renames[0..k]) |prev| {
                    if (std.mem.eql(u8, prev.zig_name, r.zig_name)) {
                        @compileError(label(i, T) ++ ".json_rename: `" ++ r.zig_name ++ "` is renamed twice");
                    }
                }
            }
        }
        if (entry.json_skip) |skip| {
            if (is_union) @compileError(label(i, T) ++ ".json_skip: json_skip applies to structs only, and " ++ @typeName(T) ++ " is a union");
            checkNamesExist(i, T, "json_skip", skip);
        }
        if (entry.json_flatten) |flatten| {
            if (is_union) @compileError(label(i, T) ++ ".json_flatten: json_flatten applies to structs only, and " ++ @typeName(T) ++ " is a union");
            checkNamesExist(i, T, "json_flatten", flatten);
            for (flatten) |name| {
                if (@typeInfo(@FieldType(T, name)) != .@"struct") {
                    @compileError(label(i, T) ++ ".json_flatten: field `" ++ name ++ "` has type " ++ @typeName(@FieldType(T, name)) ++ ", and only a struct field can be flattened");
                }
            }
        }
        if (!is_union) {
            if (entry.json_tag != null) @compileError(label(i, T) ++ ".json_tag: json_tag applies to tagged unions only, and " ++ @typeName(T) ++ " is a struct");
            if (entry.json_payload != null) @compileError(label(i, T) ++ ".json_payload: json_payload applies to tagged unions only, and " ++ @typeName(T) ++ " is a struct");
        }
        if (entry.json_tag) |tag| {
            if (entry.json_payload) |payload| {
                // Restating both declared values leaves the type-local
                // error, raised where the union is used.
                const restated = @hasDecl(T, "json_tag") and std.mem.eql(u8, tag, T.json_tag) and
                    @hasDecl(T, "json_payload") and std.mem.eql(u8, payload, T.json_payload);
                if (std.mem.eql(u8, tag, payload) and !restated) {
                    @compileError(label(i, T) ++ ".json_payload: `" ++ payload ++ "` is also the json_tag; the discriminator and the payload need different members");
                }
            }
        }
        if (entry.hooks) |Hooks| checkHooksNamespace(T, Hooks);
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

/// Instantiation-time check for struct or union `T` reached through codec
/// `C`. A union's effective `json_tag` and `json_payload` must differ. Every
/// other check is one rule over the object's layout: a codec may not create
/// a layout problem that the declarations alone do not already have where
/// it occurs.
pub fn checkUse(comptime C: type, comptime T: type) void {
    comptime {
        if (@typeInfo(T) == .@"union") checkTagPayload(C, T);
        if (C.annotations.len == 0) return;
        @setEvalBranchQuota(quadraticQuota(Budget(T).tree));
        const layout = objectLayout(C, T, &.{}, 0);
        if (!layout.touched) return;
        // Pairs sharing one key are at most quadratic in the layout's size.
        @setEvalBranchQuota(quadraticQuota(layoutSize(layout)));
        checkEach(C, T, layout, .tag_payload);
        checkKeys(C, T, layout, &.{}, 0);
        checkEach(C, T, layout, .wire_names);
        checkEach(C, T, layout, .inlined);
    }
}

/// The type's own declarations alone, to tell what a codec value changed.
const Local = Codec(.{});

/// One step of a member's path: field or variant `name` of `owner`.
const Step = struct { owner: type, name: []const u8 };

const Role = enum { field, tag, payload };

/// A member of an object. A tag or payload member belongs to union `at`.
/// The declarations alone give the member its key, from the type owning
/// its path's step `n` onward, exactly when `local_from <= n`.
const Member = struct { key: []const u8, path: []const Step, role: Role, at: type = void, local_from: usize };

const never = std.math.maxInt(usize);

const Inlined = struct { type: type, path: []const Step };

/// The members of one JSON object that its own type contributes and the
/// structs it inlines. For a union with an inline payload, `variants` holds
/// one layout per variant, whose members appear alongside these but never
/// alongside another variant's. `touched` is whether any type in the tree
/// has a codec entry.
const Layout = struct {
    members: []const Member = &.{},
    inlined: []const Inlined = &.{},
    variants: []const Layout = &.{},
    touched: bool = false,
};

/// The layout `X` contributes at `path`, from the same lookups decode and
/// encode use. A flattened non-struct field adds nothing, since decode and
/// encode do not support it; a union with no `json_tag` adds nothing. Steps
/// `pre` and later of `path` are all inlined by the declarations alone.
fn objectLayout(comptime C: type, comptime X: type, comptime path: []const Step, comptime pre: usize) Layout {
    comptime {
        const touched = C.find(X) != null;
        switch (@typeInfo(X)) {
            .@"struct" => |s| {
                var l = fieldsLayout(C, X, s.fields, path, pre);
                l.touched = l.touched or touched;
                return l;
            },
            .@"union" => |u| {
                if (X == Value) return .{};
                const tag = entryOf(C, X).json_tag orelse if (@hasDecl(X, "json_tag")) X.json_tag else return .{ .touched = touched };
                const local_tag = @hasDecl(X, "json_tag") and std.mem.eql(u8, X.json_tag, tag);
                const tag_member: Member = .{ .key = tag, .path = path, .role = .tag, .at = X, .local_from = if (local_tag) pre else never };
                if (decode_mod.getJsonPayload(X, C)) |payload| {
                    const declared = decode_mod.getJsonPayload(X, Local);
                    const local = @hasDecl(X, "json_tag") and declared != null and std.mem.eql(u8, declared.?, payload);
                    const payload_member: Member = .{ .key = payload, .path = path, .role = .payload, .at = X, .local_from = if (local) pre else never };
                    return .{ .members = &.{ tag_member, payload_member }, .touched = touched };
                }
                // Every variant step of one union is inlined alike.
                const inlined = u.fields.len != 0 and localStep(X, u.fields[0].name) == .inlined;
                var variants: [u.fields.len]Layout = undefined;
                var any = touched;
                for (u.fields, &variants) |f, *v| {
                    const at = path ++ &[_]Step{.{ .owner = X, .name = f.name }};
                    const P = Unwrapped(f.type);
                    v.* = objectLayout(C, P, at, if (inlined) pre else at.len);
                    if (@typeInfo(P) == .@"struct") v.inlined = &[_]Inlined{.{ .type = P, .path = at }} ++ v.inlined;
                    any = any or v.touched;
                }
                const fixed = variants;
                return .{ .members = &.{tag_member}, .variants = &fixed, .touched = any };
            },
            else => return .{},
        }
    }
}

/// The layout of `fields` of struct `S`, concatenated by halves to stay
/// O(n log n).
fn fieldsLayout(comptime C: type, comptime S: type, comptime fields: []const std.builtin.Type.StructField, comptime path: []const Step, comptime pre: usize) Layout {
    comptime {
        if (fields.len > 1) {
            const a = fieldsLayout(C, S, fields[0 .. fields.len / 2], path, pre);
            const b = fieldsLayout(C, S, fields[fields.len / 2 ..], path, pre);
            return .{ .members = a.members ++ b.members, .inlined = a.inlined ++ b.inlined, .touched = a.touched or b.touched };
        }
        if (fields.len == 0) return .{};
        const f = fields[0];
        if (decode_mod.isSkipped(S, C, f.name)) return .{};
        const at = path ++ &[_]Step{.{ .owner = S, .name = f.name }};
        const local = localStep(S, f.name);
        if (!decode_mod.isFlattened(S, C, f.name)) {
            const key = decode_mod.renamedKey(S, C, f.name);
            const same = local == .key and std.mem.eql(u8, local.key, key);
            return .{ .members = &.{.{ .key = key, .path = at, .role = .field, .local_from = if (same) pre else never }} };
        }
        if (@typeInfo(f.type) != .@"struct") return .{};
        var l = objectLayout(C, f.type, at, if (local == .inlined) pre else at.len);
        l.inlined = &[_]Inlined{.{ .type = f.type, .path = at }} ++ l.inlined;
        return l;
    }
}

/// Field or variant `name` of `owner` by declarations alone: left out of
/// the object, written under `key`, or inlined into the enclosing object.
fn localStep(comptime owner: type, comptime name: []const u8) union(enum) { absent, key: []const u8, inlined } {
    comptime {
        if (@typeInfo(owner) == .@"union") {
            return if (@hasDecl(owner, "json_tag") and decode_mod.getJsonPayload(owner, Local) == null) .inlined else .absent;
        }
        if (decode_mod.isSkipped(owner, Local, name)) return .absent;
        if (decode_mod.isFlattened(owner, Local, name)) return .inlined;
        return .{ .key = decode_mod.renamedKey(owner, Local, name) };
    }
}

/// `items` sorted by key, equal keys kept in order.
fn sortByKey(comptime items: []const Member) []const Member {
    comptime {
        if (items.len < 2) return items;
        const a = sortByKey(items[0 .. items.len / 2]);
        const b = sortByKey(items[items.len / 2 ..]);
        var out: [items.len]Member = undefined;
        var i = 0;
        for (&out, 0..) |*m, n| {
            const k = n - i;
            if (k == b.len or (i < a.len and std.mem.order(u8, b[k].key, a[i].key) != .lt)) {
                m.* = a[i];
                i += 1;
            } else m.* = b[k];
        }
        const fixed = out;
        return &fixed;
    }
}

fn Unwrapped(comptime P: type) type {
    return if (@typeInfo(P) == .optional) Unwrapped(@typeInfo(P).optional.child) else P;
}

fn layoutSize(comptime l: Layout) usize {
    comptime {
        var n = l.members.len + l.inlined.len + l.variants.len;
        for (l.variants) |v| n += layoutSize(v);
        return n;
    }
}

/// Runs one check on every union or inlined struct of `l`, outer first.
fn checkEach(comptime C: type, comptime T: type, comptime l: Layout, comptime check: enum { tag_payload, wire_names, inlined }) void {
    comptime {
        switch (check) {
            .tag_payload => for (l.members) |m| {
                if (m.role == .tag) checkTagPayload(C, m.at);
            },
            .wire_names => for (l.members) |m| {
                if (m.role == .tag) checkWireNames(C, T, m.at, m.path);
            },
            .inlined => for (l.inlined) |s| checkInlined(C, T, s.type, s.path),
        }
        for (l.variants) |v| checkEach(C, T, v, check);
    }
}

/// Two members that can appear together may share a key only when the
/// innermost type owning both gives them that key by its declarations.
/// A layout's members appear with each other and with `outer`, those of the
/// layouts enclosing it, but never with another variant's, so only those
/// pairs are compared, and only where the keys are equal and one member's
/// key is not the declarations' from `depth`, the path length all share.
fn checkKeys(comptime C: type, comptime T: type, comptime l: Layout, comptime outer: []const Member, comptime depth: usize) void {
    comptime {
        const members = sortByKey(l.members);
        var start = 0;
        while (start < members.len) {
            var end = start + 1;
            while (end < members.len and std.mem.eql(u8, members[end].key, members[start].key)) end += 1;
            const run = members[start..end];
            for (outer) |o| {
                if (std.mem.eql(u8, o.key, run[0].key)) for (run) |m| checkPair(C, T, o, m);
            }
            for (run, 0..) |a, i| {
                if (a.local_from <= depth) continue;
                for (run, 0..) |b, k| {
                    if (k < i and b.local_from > depth) continue;
                    if (k < i) checkPair(C, T, b, a) else if (k > i) checkPair(C, T, a, b);
                }
            }
            start = end;
        }
        for (l.variants) |v| checkKeys(C, T, v, outer ++ l.members, depth + 1);
    }
}

/// `a` and `b` share a key; `a` comes first in the object.
fn checkPair(comptime C: type, comptime T: type, comptime a: Member, comptime b: Member) void {
    comptime {
        var n: usize = 0;
        while (n < a.path.len and n < b.path.len and std.mem.eql(u8, a.path[n].name, b.path[n].name)) n += 1;
        if (a.local_from <= n and b.local_from <= n) return;
        @compileError(@typeName(T) ++ ": key `" ++ a.key ++ "` comes from both " ++ describe(C, a) ++ " and " ++ describe(C, b) ++
            "; members of one object may share a key only where the declarations alone already give it to both");
    }
}

/// Decode takes the first variant whose wire name matches, so two variants
/// sharing one leave the second unreachable. Without a codec `json_rename`
/// every wire name is the declared one.
fn checkWireNames(comptime C: type, comptime T: type, comptime U: type, comptime path: []const Step) void {
    comptime {
        if (entryOf(C, U).json_rename == null) return;
        const fields = @typeInfo(U).@"union".fields;
        var names: [fields.len]Member = undefined;
        for (fields, &names) |f, *m| {
            const name = decode_mod.renamedKey(U, C, f.name);
            const same = std.mem.eql(u8, decode_mod.renamedKey(U, Local, f.name), name);
            m.* = .{ .key = name, .path = &.{.{ .owner = U, .name = f.name }}, .role = .field, .local_from = if (same) 0 else never };
        }
        const sorted = sortByKey(&names);
        for (sorted[1..], 1..) |b, k| {
            const a = sorted[k - 1];
            if (!std.mem.eql(u8, a.key, b.key) or (a.local_from == 0 and b.local_from == 0)) continue;
            const where = if (path.len == 0) "" else " at " ++ pathName(path);
            @compileError(@typeName(T) ++ ": variants `" ++ a.path[0].name ++ "` and `" ++ b.path[0].name ++ "` of " ++ @typeName(U) ++ where ++
                " both have the wire name `" ++ a.key ++ "` (shaped by " ++ entryLabel(C, U) ++ ".json_rename); variants may share a wire name only where the declarations alone already give it to both");
        }
    }
}

/// An inlined struct is decoded by its `fromJson` but encoded by reflection,
/// so one with hooks is allowed only where the declarations alone inline it
/// with the same hooks.
fn checkInlined(comptime C: type, comptime T: type, comptime S: type, comptime path: []const Step) void {
    comptime {
        const from = decode_mod.hasFromJson(S, C);
        const to = decode_mod.hasToJson(S, C);
        if (!from and !to) return;
        const Hooks = decode_mod.HookSource(S, C);
        const same_hooks = for ([_][]const u8{ "fromJson", "toJson" }) |name| {
            if (@hasDecl(Hooks, name) != @hasDecl(S, name)) break false;
            if (@hasDecl(S, name) and @field(Hooks, name) != @field(S, name)) break false;
        } else true;
        const last = path[path.len - 1];
        if (same_hooks and localStep(last.owner, last.name) == .inlined) return;
        var cause = causes(C, path, null, void);
        if (!same_hooks) cause = join(cause, entryLabel(C, S) ++ ".hooks", " and ");
        const as = if (@typeInfo(last.owner) == .@"union") "an inline payload" else "a flattened struct";
        const what = if (from and to)
            "has fromJson and toJson; " ++ as ++ " is decoded by its fromJson but encoded by reflection instead of its toJson"
        else if (from)
            "has fromJson; " ++ as ++ " is decoded by its fromJson but encoded by reflection"
        else
            "has toJson; " ++ as ++ " is encoded by reflection instead of its toJson";
        const subject = if (@typeInfo(last.owner) == .@"union")
            pathName(path) ++ " inlines " ++ @typeName(S) ++ ", which " ++ what
        else
            pathName(path) ++ " is flattened, but " ++ @typeName(S) ++ " " ++ what;
        @compileError(@typeName(T) ++ ": " ++ subject ++ ", so " ++ cause ++ " may not combine the two");
    }
}

/// `path` in words: its variant steps, then its field steps as one dotted
/// field. Only a variant's payload can be another union, so variant steps
/// all come first.
fn pathName(comptime path: []const Step) []const u8 {
    comptime {
        var variants: []const u8 = "";
        var fields: []const u8 = "";
        for (path) |s| {
            if (@typeInfo(s.owner) == .@"union") {
                variants = join(variants, "variant `" ++ s.name ++ "`", "'s ");
            } else fields = join(fields, s.name, ".");
        }
        return join(variants, if (fields.len == 0) "" else "field `" ++ fields ++ "`", "'s ");
    }
}

fn describe(comptime C: type, comptime m: Member) []const u8 {
    const what = switch (m.role) {
        .field => pathName(m.path),
        .tag, .payload => "the json_" ++ @tagName(m.role) ++ (if (m.path.len == 0) "" else " of " ++ @typeName(m.at) ++ " at " ++ pathName(m.path)),
    };
    const cause = causes(C, m.path, m.role, m.at);
    return if (cause.len == 0) what else what ++ " (shaped by " ++ cause ++ ")";
}

/// The codec properties along `path` that differ from the declarations:
/// those that bring the member (with `role`, or an inlined struct when
/// null) into the object or change its key.
fn causes(comptime C: type, comptime path: []const Step, comptime role: ?Role, comptime at: type) []const u8 {
    comptime {
        var list: []const []const u8 = &.{};
        for (path, 0..) |s, k| {
            const X = s.owner;
            if (@typeInfo(X) == .@"union") {
                if (!@hasDecl(X, "json_tag")) list = addCause(list, entryLabel(C, X) ++ ".json_tag");
                continue;
            }
            if (decode_mod.isSkipped(X, C, s.name) != decode_mod.isSkipped(X, Local, s.name)) list = addCause(list, entryLabel(C, X) ++ ".json_skip");
            if (decode_mod.isFlattened(X, C, s.name) != decode_mod.isFlattened(X, Local, s.name)) list = addCause(list, entryLabel(C, X) ++ ".json_flatten");
            if (k + 1 == path.len and role == .field and
                !std.mem.eql(u8, decode_mod.renamedKey(X, C, s.name), decode_mod.renamedKey(X, Local, s.name)))
            {
                list = addCause(list, entryLabel(C, X) ++ ".json_rename");
            }
        }
        if (role == .tag and tagByCodec(C, at)) list = addCause(list, entryLabel(C, at) ++ ".json_tag");
        if (role == .payload and payloadByCodec(C, at)) list = addCause(list, entryLabel(C, at) ++ ".json_payload");
        var out: []const u8 = "";
        for (list) |cause| out = join(out, cause, ", ");
        return out;
    }
}

fn addCause(comptime list: []const []const u8, comptime cause: []const u8) []const []const u8 {
    for (list) |c| {
        if (std.mem.eql(u8, c, cause)) return list;
    }
    return list ++ &[_][]const u8{cause};
}

/// `label` for the entry `C` holds for `T`, which must exist.
fn entryLabel(comptime C: type, comptime T: type) []const u8 {
    comptime {
        for (C.annotations, 0..) |entry, i| {
            if (@TypeOf(entry) == Annotations(T)) return label(i, T);
        }
        unreachable;
    }
}

fn join(comptime a: []const u8, comptime b: []const u8, comptime sep: []const u8) []const u8 {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    return a ++ sep ++ b;
}

/// Whether `U`'s effective `json_tag` differs from its own declaration.
fn tagByCodec(comptime C: type, comptime U: type) bool {
    const tag = entryOf(C, U).json_tag orelse return false;
    return !@hasDecl(U, "json_tag") or !std.mem.eql(u8, tag, U.json_tag);
}

/// Whether `U`'s effective `json_payload` differs from its own declaration.
fn payloadByCodec(comptime C: type, comptime U: type) bool {
    const payload = entryOf(C, U).json_payload orelse return false;
    const local = decode_mod.getJsonPayload(U, Local) orelse return true;
    return !std.mem.eql(u8, payload, local);
}

/// The effective `json_tag` and `json_payload` of union `U` must differ.
fn checkTagPayload(comptime C: type, comptime U: type) void {
    comptime {
        const payload = decode_mod.getJsonPayload(U, C) orelse return;
        const tag = decode_mod.getJsonTag(U, C);
        if (!std.mem.eql(u8, tag, payload)) return;
        const where = if (tagByCodec(C, U))
            entryLabel(C, U) ++ ".json_tag"
        else if (payloadByCodec(C, U))
            entryLabel(C, U) ++ ".json_payload"
        else
            @typeName(U) ++ ".json_payload";
        @compileError(where ++ ": json_tag and json_payload of " ++ @typeName(U) ++ " are both `" ++ tag ++
            "`; the discriminator and the payload need different members");
    }
}

/// Comptime branch budget for work that grows with the square of `n`, so a
/// large type never hits the default limit. Capped at the largest quota
/// `@setEvalBranchQuota` accepts.
fn quadraticQuota(comptime n: comptime_int) comptime_int {
    return @min(10_000 + 100 * n * n, std.math.maxInt(u32));
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

        /// At least the size of any layout of `T`: fields and variants of
        /// `T` and of every struct or union under them, optionals unwrapped.
        const tree: usize = count: switch (@typeInfo(T)) {
            inline .@"struct", .@"union" => |info| {
                if (T == Value) break :count 0;
                @setEvalBranchQuota(1000 + 10 * info.fields.len);
                var n: usize = 2 * info.fields.len + 2;
                for (info.fields) |f| n +|= Budget(Unwrapped(f.type)).tree;
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

test "codec: json_skip without a default encodes, and a codec fromJson decodes it" {
    const Foreign = struct { name: []const u8, internal: u32 };
    const Skipping = Codec(.{Annotations(Foreign){ .json_skip = &.{"internal"} }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v: Foreign = .{ .name = "x", .internal = 3 };
    try std.testing.expectEqualStrings("{\"name\":\"x\"}", try encodeAlloc(Skipping, a, v, .{}));

    const Decoding = Codec(.{Annotations(Foreign){ .json_skip = &.{"internal"}, .hooks = struct {
        pub fn fromJson(arena: Allocator, value: Value, options: ParseOptions) DecodeError!Foreign {
            const Wire = struct { name: []const u8 };
            const wire = try decode_mod.decode(Wire, Codec(.{}), arena, value, options);
            return .{ .name = wire.name, .internal = 0 };
        }
    } }});
    try std.testing.expectEqualStrings("{\"name\":\"x\"}", try encodeAlloc(Decoding, a, v, .{}));
    const back = try Decoding.parseInto(Foreign, a, "{\"name\":\"x\"}", .{});
    try std.testing.expectEqualStrings("x", back.name);
    try std.testing.expectEqual(@as(u32, 0), back.internal);
}

test "codec: key collisions from declarations alone keep their behavior under a codec" {
    const Inner = struct { a: u8 };
    const T = struct {
        pub const json_rename = .{ .x = "k", .y = "k" };
        pub const json_flatten = .{"inner"};
        x: u8,
        y: u8,
        a: u8,
        inner: Inner,
    };
    const Other = struct { z: u8 };
    const C = Codec(.{Annotations(Other){ .json_rename = &.{} }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try C.parseInto(T, a, "{\"k\":1,\"a\":2}", .{});
    try std.testing.expectEqual(T{ .x = 1, .y = 1, .a = 2, .inner = .{ .a = 2 } }, got);
    const global = try decode_mod.parseInto(T, Codec(.{}), a, "{\"k\":1,\"a\":2}", .{});
    try std.testing.expectEqual(got, global);
}

test "codec: key collisions from declarations alone stay allowed beside the type's other codec values" {
    const T = struct {
        pub const json_rename = .{ .x = "k", .y = "k" };
        x: u8,
        y: u8,
        z: u8 = 0,
    };
    const C = Codec(.{Annotations(T){ .json_skip = &.{"z"} }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const got = try C.parseInto(T, ar.allocator(), "{\"k\":1}", .{});
    try std.testing.expectEqual(T{ .x = 1, .y = 1, .z = 0 }, got);
}

test "codec: variants sharing a declared wire name keep first-match decoding" {
    const U = union(enum) {
        pub const json_tag = "t";
        pub const json_rename = .{ .a = "x", .b = "x" };
        a: void,
        b: void,
    };
    const C = Codec(.{Annotations(U){ .json_tag = "kind" }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectEqual(U.a, try C.parseInto(U, ar.allocator(), "{\"kind\":\"x\"}", .{}));
}

test "codec: an entry restating a hooked struct's declared json_flatten decodes as the declarations do" {
    const H = struct {
        x: u8,

        pub fn fromJson(_: Allocator, value: Value, _: ParseOptions) DecodeError!@This() {
            return .{ .x = @intCast(value.object.count()) };
        }
    };
    const T = struct {
        pub const json_flatten = .{"h"};
        a: u8,
        h: H,
    };
    const C = Codec(.{Annotations(T){ .json_flatten = &.{"h"} }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try C.parseInto(T, a, "{\"a\":1}", .{});
    try std.testing.expectEqual(T{ .a = 1, .h = .{ .x = 1 } }, got);
    try std.testing.expectEqual(got, try decode_mod.parseInto(T, Codec(.{}), a, "{\"a\":1}", .{}));
}

test "codec: a codec flatten bringing in a declared collision keeps its behavior" {
    const S = struct {
        pub const json_rename = .{ .x = "k", .y = "k" };
        x: u8,
        y: u8,
    };
    const T = struct { a: u8, s: S };
    const Declared = struct {
        pub const json_flatten = .{"s"};
        a: u8,
        s: S,
    };
    const C = Codec(.{Annotations(T){ .json_flatten = &.{"s"} }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try C.parseInto(T, a, "{\"a\":1,\"k\":2}", .{});
    try std.testing.expectEqual(T{ .a = 1, .s = .{ .x = 2, .y = 2 } }, got);
    const declared = try decode_mod.parseInto(Declared, Codec(.{}), a, "{\"a\":1,\"k\":2}", .{});
    try std.testing.expectEqual(got.s, declared.s);
}

test "codec: entries restating declared values keep declared collisions" {
    const T = struct {
        pub const json_rename = .{ .a = "k" };
        a: u8,
        k: u8,
    };
    const V = struct { t: u8 };
    const U = union(enum) {
        pub const json_tag = "t";
        v: V,
    };
    const C = Codec(.{
        Annotations(T){ .json_rename = &.{.{ .zig_name = "a", .json_name = "k" }} },
        Annotations(U){ .json_tag = "t" },
    });
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try C.parseInto(T, a, "{\"k\":3}", .{});
    try std.testing.expectEqual(got, try decode_mod.parseInto(T, Codec(.{}), a, "{\"k\":3}", .{}));
    try std.testing.expectEqual(T{ .a = 3, .k = 3 }, got);
    const src = "{\"t\":\"v\"}";
    const want = decode_mod.parseInto(U, Codec(.{}), a, src, .{});
    try std.testing.expectError(error.MissingField, want);
    try std.testing.expectError(error.MissingField, C.parseInto(U, a, src, .{}));
}

test "codec: an entry dropping one of several members sharing a declared key keeps the rest" {
    const T = struct {
        pub const json_rename = .{ .a = "k", .b = "k", .c = "k" };
        a: u8,
        b: u8,
        c: u8 = 0,
    };
    const C = Codec(.{Annotations(T){ .json_rename = &.{
        .{ .zig_name = "a", .json_name = "k" },
        .{ .zig_name = "b", .json_name = "k" },
    } }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectEqual(T{ .a = 1, .b = 1, .c = 2 }, try C.parseInto(T, ar.allocator(), "{\"k\":1,\"c\":2}", .{}));
}

test "codec: members of different variants may share a key" {
    const P = struct { id: u8 };
    const Q = struct { y: u8 };
    const U = union(enum) {
        pub const json_tag = "kind";
        a: P,
        b: Q,
    };
    const C = Codec(.{Annotations(Q){ .json_rename = &.{.{ .zig_name = "y", .json_name = "id" }} }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try expectRoundTrip(C, U, a, .{ .a = .{ .id = 3 } }, "{\"kind\":\"a\",\"id\":3}", .{ .a = .{ .id = 3 } });
    try expectRoundTrip(C, U, a, .{ .b = .{ .y = 4 } }, "{\"kind\":\"b\",\"id\":4}", .{ .b = .{ .y = 4 } });
}

test "codec: hooks restating a flattened struct's own fromJson decode as the declarations do" {
    const H = struct {
        x: u8,

        pub fn fromJson(_: Allocator, value: Value, _: ParseOptions) DecodeError!@This() {
            return .{ .x = @intCast(value.object.count()) };
        }
    };
    const T = struct {
        pub const json_flatten = .{"h"};
        a: u8,
        h: H,
    };
    const C = Codec(.{Annotations(H){ .hooks = struct {
        pub const fromJson = H.fromJson;
    } }});
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try C.parseInto(T, a, "{\"a\":1}", .{});
    try std.testing.expectEqual(T{ .a = 1, .h = .{ .x = 1 } }, got);
    try std.testing.expectEqual(got, try decode_mod.parseInto(T, Codec(.{}), a, "{\"a\":1}", .{}));
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
