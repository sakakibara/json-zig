// Lossless document editing: parse JSONC, read, modify, emit.
//
// Demonstrates: Document.parse with .jsonc dialect, Document.getT,
// Document.set, Document.setLiteral, Document.addCommentBefore,
// and Document.emit. The emitted document differs from the input only
// where edits were applied; all other bytes (comments, formatting,
// trailing commas) are preserved exactly.

const std = @import("std");
const json = @import("json");

// A JSONC config -- comments and trailing commas are valid.
const src =
    \\{
    \\  // server settings
    \\  "host": "localhost",
    \\  "port": 8080,
    \\  "tls": false,
    \\}
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try json.Document.parse(a, src, .{ .dialect = .jsonc });

    // Read through the document before editing.
    const port_before = doc.getT(u16, "port").?;
    std.debug.print("port before: {d}\n", .{port_before});

    // Replace an existing value in-place (surrounding bytes untouched).
    try doc.set("port", @as(u16, 9443));

    // Flip an existing boolean.
    try doc.set("tls", true);

    // Append a new key; style is inferred from siblings (multiline -> comma+indent).
    try doc.setLiteral("workers", "4");

    // Prepend a comment line before the host value (JSONC only).
    try doc.addCommentBefore("host", "bind address");

    // Emit the modified document into an allocating writer, then print.
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);

    std.debug.print("--- emitted document ---\n{s}", .{aw.written()});
}
