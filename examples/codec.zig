// Codec: annotate a type that cannot carry declarations.
//
// Demonstrates: json.Codec with an Annotations(T) entry for a tagged
// union built with @Union, which cannot declare json_tag or json_rename,
// a rename table generated at comptime from the union's variants, and a
// round trip through Codec.parseInto and Codec.encodeTyped.

const std = @import("std");
const json = @import("json");

const Circle = struct { radius: f64 };
const Rect = struct { width: f64, height: f64 };

// Variant name and payload type, as a code generator might emit them.
const variants = .{
    .{ "circle", Circle },
    .{ "rect", Rect },
};

const Shape = blk: {
    var names: [variants.len][]const u8 = undefined;
    var types: [variants.len]type = undefined;
    for (variants, 0..) |v, i| {
        names[i] = v[0];
        types[i] = v[1];
    }
    const Tag = @Enum(u8, .exhaustive, &names, &std.simd.iota(u8, variants.len));
    break :blk @Union(.auto, Tag, &names, &types, &@splat(.{}));
};

// The wire names every variant "Geometry.<Name>", generated rather than
// written out per variant.
const shape_renames = blk: {
    const fields = @typeInfo(Shape).@"union".fields;
    var renames: [fields.len]json.AnnotationRename = undefined;
    for (fields, 0..) |f, i| {
        const first = [_]u8{std.ascii.toUpper(f.name[0])};
        renames[i] = .{ .zig_name = f.name, .json_name = "Geometry." ++ first ++ f.name[1..] };
    }
    const final = renames;
    break :blk final;
};

const ShapeCodec = json.Codec(.{
    json.Annotations(Shape){ .json_tag = "$type", .json_rename = &shape_renames },
});

const Drawing = struct {
    title: []const u8,
    shapes: []const Shape,
};

const src =
    \\{
    \\  "title": "demo",
    \\  "shapes": [
    \\    { "$type": "Geometry.Circle", "radius": 1.5 },
    \\    { "$type": "Geometry.Rect", "width": 2.0, "height": 3.0 }
    \\  ]
    \\}
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const drawing = try ShapeCodec.parseInto(Drawing, a, src, .{});
    for (drawing.shapes) |shape| switch (shape) {
        .circle => |c| std.debug.print("circle r={d}\n", .{c.radius}),
        .rect => |r| std.debug.print("rect {d}x{d}\n", .{ r.width, r.height }),
    };

    var aw: std.Io.Writer.Allocating = .init(a);
    try ShapeCodec.encodeTyped(&aw.writer, drawing, a, .{ .indent = 2 });
    std.debug.print("{s}\n", .{aw.written()});
}
