// Dynamic parse + dotted-path access with getT.
//
// Demonstrates: json.parse, Value.getT with int/float/bool/string types,
// array index syntax ([N]), and walking a nested object path.

const std = @import("std");
const json = @import("json");

const src =
    \\{
    \\  "server": {
    \\    "host": "localhost",
    \\    "port": 8080,
    \\    "tls": false
    \\  },
    \\  "limits": {
    \\    "rate": 1.5,
    \\    "queue": 64
    \\  },
    \\  "tags": ["json", "zig", "fast"]
    \\}
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const v = try json.parse(arena.allocator(), src, .{});

    const host = v.getT([]const u8, "server.host").?;
    const port = v.getT(i64, "server.port").?;
    const tls = v.getT(bool, "server.tls").?;
    const rate = v.getT(f64, "limits.rate").?;
    const tag0 = v.getT([]const u8, "tags[0]").?;
    const tag2 = v.getT([]const u8, "tags[2]").?;

    std.debug.print("host:  {s}\n", .{host});
    std.debug.print("port:  {d}\n", .{port});
    std.debug.print("tls:   {}\n", .{tls});
    std.debug.print("rate:  {d}\n", .{rate});
    std.debug.print("tag[0]: {s}\n", .{tag0});
    std.debug.print("tag[2]: {s}\n", .{tag2});

    // getT returns null on type mismatch -- no error, just null.
    const bad = v.getT(i64, "server.host");
    std.debug.print("wrong-type lookup: {?}\n", .{bad});
}
