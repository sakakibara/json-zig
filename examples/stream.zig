// Incremental event reader: four front-ends on in-program buffers.
//
// Shows: EventReader.fromReader (SAX walk), feed-core with NeedMoreInput,
// ValueStream over NDJSON, and skip-then-materialize.

const std = @import("std");
const json = @import("json");

// Section 1: reader-backed SAX walk -- print object keys at depth 1.
fn section1(gpa: std.mem.Allocator) !void {
    const data =
        \\[{"name":"alice","age":30},{"name":"bob","age":25}]
    ;
    var r: std.Io.Reader = .fixed(data);
    var er = json.EventReader.fromReader(gpa, &r, .{});
    defer er.deinit();

    std.debug.print("section 1: object keys at depth 1\n", .{});
    var depth: usize = 0;
    while (try er.next()) |ev| {
        switch (ev.kind) {
            .array_begin, .object_begin => depth += 1,
            .array_end, .object_end => depth -= 1,
            .object_key => |k| if (depth == 2) {
                std.debug.print("  key: {s}\n", .{k});
            },
            .end_of_input => break,
            else => {},
        }
    }
}

// Section 2: feed-core -- send a document in three chunks, handle NeedMoreInput.
fn section2(gpa: std.mem.Allocator) !void {
    const chunks = [_][]const u8{ "{\"x\":", "42,\"y", "\":7}" };
    var er = json.EventReader.init(gpa, .{});
    defer er.deinit();

    std.debug.print("section 2: feed in 3 chunks\n", .{});
    var chunk_idx: usize = 0;
    outer: while (true) {
        const ev = er.next() catch |e| switch (e) {
            // Recoverable: feed the next chunk and retry.
            error.NeedMoreInput => {
                if (chunk_idx < chunks.len) {
                    try er.feed(chunks[chunk_idx]);
                    chunk_idx += 1;
                } else {
                    er.endInput();
                }
                continue;
            },
            else => return e,
        };
        const event = ev orelse break :outer;
        switch (event.kind) {
            .object_key => |k| std.debug.print("  key: {s}\n", .{k}),
            .number => |n| std.debug.print("  number: {s}\n", .{n}),
            .end_of_input => break :outer,
            else => {},
        }
    }
}

// Section 3: ValueStream over NDJSON -- one Value per record, arena reset between records.
fn section3(gpa: std.mem.Allocator) !void {
    const ndjson = "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n";
    var r: std.Io.Reader = .fixed(ndjson);
    var vs = json.ValueStream.fromReader(gpa, &r, .{ .shape = .multi_document });
    defer vs.deinit();

    std.debug.print("section 3: NDJSON records\n", .{});
    var item_arena: std.heap.ArenaAllocator = .init(gpa);
    defer item_arena.deinit();
    while (try vs.next(item_arena.allocator())) |record| {
        const n = record.getT(i64, "n").?;
        std.debug.print("  n={d}\n", .{n});
        // Reset the per-item arena so each record's allocation is bounded.
        _ = item_arena.reset(.retain_capacity);
    }
}

// Section 4: skip-then-materialize -- stream an array, skip until index 2,
// materialize that element as a Value.
fn section4(gpa: std.mem.Allocator) !void {
    const data =
        \\[{"v":10},{"v":20},{"v":30},{"v":40}]
    ;
    var r: std.Io.Reader = .fixed(data);
    var er = json.EventReader.fromReader(gpa, &r, .{});
    defer er.deinit();

    std.debug.print("section 4: materialize element at index 2\n", .{});

    // Consume the outer array_begin.
    _ = try er.next();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var idx: usize = 0;
    while (try er.next()) |ev| {
        switch (ev.kind) {
            .array_end, .end_of_input => break,
            .object_begin => {
                if (idx == 2) {
                    // Materialize this element (object_begin is the last event).
                    const val = try er.materialize(arena.allocator());
                    const v = val.getT(i64, "v").?;
                    std.debug.print("  element[2].v = {d}\n", .{v});
                    break;
                } else {
                    // Skip: drain events until the matching object_end.
                    var depth: usize = 1;
                    while (depth > 0) {
                        const inner = (try er.next()) orelse break;
                        switch (inner.kind) {
                            .object_begin, .array_begin => depth += 1,
                            .object_end, .array_end => depth -= 1,
                            else => {},
                        }
                    }
                    idx += 1;
                }
            },
            else => {},
        }
    }
}

pub fn main() !void {
    // page_allocator is sufficient for examples; EventReader owns its own
    // internal buffers and frees them in deinit().
    const gpa = std.heap.page_allocator;

    try section1(gpa);
    try section2(gpa);
    try section3(gpa);
    try section4(gpa);
}
