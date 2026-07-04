//! Microbenchmarks. Always built ReleaseFast (see build.zig).
//!
//! Each benchmark runs `warmup_count` untimed iterations, then
//! `sample_count` timed ones, and reports min/p50/p99/max latency plus
//! throughput (MB/s at the median). Per-iteration allocations go into an
//! arena that is reset (capacity retained) between iterations, so steady
//! state timing excludes page-faulting fresh memory.
//!
//! Fixtures live in `bench/fixtures/`; the path is injected by build.zig
//! as the `bench_options.fixtures_path` build option, so the bench runs
//! from any cwd.
//!
//! The streaming bench builds a large synthetic JSON array in memory once,
//! then streams it via ValueStream with a per-item arena reset between
//! items. A counting allocator wrapper around the EventReader's gpa tracks
//! peak outstanding bytes, proving bounded reader memory regardless of
//! total document size.

const std = @import("std");
const Io = std.Io;
const json = @import("json");
const bench_options = @import("bench_options");

const warmup_count: usize = 10;
const sample_count: usize = 100;
const max_fixture_bytes: usize = 4 << 20;

const fixture_names = [_][]const u8{ "small.json", "medium.json", "large.json" };

/// Typed mirror of small.json for the parseInto benchmark.
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const static = init.arena.allocator();

    var dir = try Io.Dir.openDirAbsolute(io, bench_options.fixtures_path, .{});
    defer dir.close(io);

    var fixtures: [fixture_names.len][]u8 = undefined;
    for (fixture_names, 0..) |name, i| {
        fixtures[i] = try dir.readFileAlloc(io, name, static, .limited(max_fixture_bytes));
    }

    std.debug.print(
        "{s:<32} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10} {s:>9}\n",
        .{ "benchmark", "size", "min", "p50", "p99", "max", "MB/s" },
    );

    for (fixture_names, fixtures) |name, src| {
        try benchParse(io, gpa, "parse (strict)", name, src, .json);
    }
    for (fixture_names, fixtures) |name, src| {
        try benchParse(io, gpa, "parse (jsonc)", name, src, .jsonc);
    }
    for (fixture_names, fixtures) |name, src| {
        try benchEncode(io, gpa, static, "encode (compact)", name, src, .compact);
    }
    for (fixture_names, fixtures) |name, src| {
        try benchEncode(io, gpa, static, "encode pretty", name, src, .pretty);
    }
    for (fixture_names, fixtures) |name, src| {
        try benchDocumentCycle(io, gpa, name, src);
    }
    try benchParseInto(io, gpa, "parseInto (typed)", "small.json", fixtures[0]);
    try benchStreamArray(io, gpa);
}

fn benchParse(io: Io, gpa: std.mem.Allocator, label: []const u8, fixture: []const u8, src: []const u8, dialect: json.Dialect) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var samples: [sample_count]u64 = undefined;

    var i: usize = 0;
    while (i < warmup_count + sample_count) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const t0: Io.Timestamp = .now(io, .awake);
        const v = try json.parse(arena.allocator(), src, .{ .dialect = dialect });
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(&v);
        if (i >= warmup_count) samples[i - warmup_count] = ns;
    }
    report(label, fixture, src.len, &samples);
}

fn benchEncode(io: Io, gpa: std.mem.Allocator, static: std.mem.Allocator, label: []const u8, fixture: []const u8, src: []const u8, mode: enum { compact, pretty }) !void {
    // Parse once outside the timed region; only encoding is measured.
    const v = try json.parse(static, src, .{});

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var samples: [sample_count]u64 = undefined;
    var out_len: usize = 0;

    var i: usize = 0;
    while (i < warmup_count + sample_count) : (i += 1) {
        aw.clearRetainingCapacity();
        const t0: Io.Timestamp = .now(io, .awake);
        switch (mode) {
            .compact => try json.encode(&aw.writer, v, .{}),
            .pretty => try json.encode(&aw.writer, v, .{ .indent = 2 }),
        }
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        out_len = aw.written().len;
        if (i >= warmup_count) samples[i - warmup_count] = ns;
    }
    // Throughput is measured against the bytes produced, not the
    // fixture size: pretty output is several times larger than input.
    report(label, fixture, out_len, &samples);
}

fn benchDocumentCycle(io: Io, gpa: std.mem.Allocator, fixture: []const u8, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var samples: [sample_count]u64 = undefined;

    var i: usize = 0;
    while (i < warmup_count + sample_count) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        aw.clearRetainingCapacity();
        const t0: Io.Timestamp = .now(io, .awake);
        const doc = try json.Document.parse(arena.allocator(), src, .{});
        try doc.emit(&aw.writer);
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        if (i >= warmup_count) samples[i - warmup_count] = ns;
        if (!std.mem.eql(u8, src, aw.written())) return error.EmitNotLossless;
    }
    report("Document parse+emit", fixture, src.len, &samples);
}

fn benchParseInto(io: Io, gpa: std.mem.Allocator, label: []const u8, fixture: []const u8, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var samples: [sample_count]u64 = undefined;

    var i: usize = 0;
    while (i < warmup_count + sample_count) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const t0: Io.Timestamp = .now(io, .awake);
        const cfg = try json.parseInto(Config, arena.allocator(), src, .{});
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(&cfg);
        if (i >= warmup_count) samples[i - warmup_count] = ns;
    }
    report(label, fixture, src.len, &samples);
}

// Allocator wrapper that tracks current outstanding bytes and peak outstanding
// bytes. Wraps an underlying allocator and forwards all operations to it, updating
// counters on alloc/free/resize. The wrapped allocator is responsible for the
// actual memory; this layer only instruments it.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    current: usize = 0,
    peak: usize = 0,

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(n, alignment, ret_addr) orelse return null;
        self.current += n;
        if (self.current > self.peak) self.peak = self.current;
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(buf, alignment, new_len, ret_addr)) return false;
        if (new_len > buf.len) {
            self.current += new_len - buf.len;
            if (self.current > self.peak) self.peak = self.current;
        } else {
            self.current -= buf.len - new_len;
        }
        return true;
    }

    // remap: try in-place resize first; if it fails, return null (caller must alloc+copy).
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        if (new_len > buf.len) {
            self.current += new_len - buf.len;
            if (self.current > self.peak) self.peak = self.current;
        } else {
            self.current -= buf.len - new_len;
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, alignment, ret_addr);
        self.current -= buf.len;
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
};

// Peak outstanding bytes the EventReader/ValueStream is allowed to hold at any
// point while streaming a million-element array. The sliding-buffer design keeps
// at most one element + internal structure in flight; a few hundred KB is generous.
const stream_memory_cap: usize = 512 * 1024;

// Synthetic element template: `{"id":<n>,"name":"x","ok":true}`.
// The largest n is 999999 (6 digits), so each element is at most 37 bytes.
// 1,000,000 elements * ~40 bytes + 2 brackets + 999,999 commas = ~40 MB total.
const stream_element_count: usize = 1_000_000;

fn benchStreamArray(io: Io, gpa: std.mem.Allocator) !void {
    // Build synthetic input once outside the timed loop.
    var doc_buf: std.ArrayList(u8) = .empty;
    defer doc_buf.deinit(gpa);

    try doc_buf.ensureTotalCapacity(gpa, stream_element_count * 38 + 16);
    try doc_buf.append(gpa, '[');
    var k: usize = 0;
    while (k < stream_element_count) : (k += 1) {
        if (k > 0) try doc_buf.append(gpa, ',');
        // Append `{"id":<k>,"name":"x","ok":true}` directly into buf.
        const written = try std.fmt.bufPrint(
            doc_buf.unusedCapacitySlice(),
            "{{\"id\":{d},\"name\":\"x\",\"ok\":true}}",
            .{k},
        );
        doc_buf.items.len += written.len;
    }
    try doc_buf.append(gpa, ']');

    const total_bytes = doc_buf.items.len;

    // Per-item arena for materializing each element; reset between items.
    var item_arena = std.heap.ArenaAllocator.init(gpa);
    defer item_arena.deinit();

    // Counting allocator wrapping gpa for the EventReader's own working memory.
    var counter: CountingAllocator = .{ .backing = gpa };
    const counting_gpa = counter.allocator();

    // Warmup pass (untimed): prime memory paths. After deinit, current
    // returns to 0 (all warmup allocations freed), so we can reset peak
    // safely between passes.
    {
        var r: std.Io.Reader = .fixed(doc_buf.items);
        var vs = json.ValueStream.fromReader(counting_gpa, &r, .{ .shape = .array_elements });
        while (try vs.next(item_arena.allocator())) |_| {
            _ = item_arena.reset(.retain_capacity);
        }
        vs.deinit();
        // After deinit, all reader allocations are freed and current == 0.
        // Reset peak so the timed pass measures only its own steady state.
        counter.peak = 0;
    }

    // Timed pass.
    const t0: Io.Timestamp = .now(io, .awake);
    {
        var r: std.Io.Reader = .fixed(doc_buf.items);
        var vs = json.ValueStream.fromReader(counting_gpa, &r, .{ .shape = .array_elements });
        while (try vs.next(item_arena.allocator())) |_| {
            _ = item_arena.reset(.retain_capacity);
        }
        vs.deinit();
    }
    const elapsed_ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);

    const peak_kb = (counter.peak + 1023) / 1024;
    const mbps = (@as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0)) /
        (@as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s);

    var size_buf: [16]u8 = undefined;
    const size = std.fmt.bufPrint(&size_buf, "{Bi:.1}", .{total_bytes}) catch "?";

    std.debug.print("{s:<32} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10} {d:>9.1}\n", .{
        "stream (array_elements)", size, "-", fmtNs(elapsed_ns), "-", "-", mbps,
    });
    std.debug.print("  stream peak reader mem: {d} KiB (cap {d} KiB)\n", .{
        peak_kb, stream_memory_cap / 1024,
    });
    if (counter.peak > stream_memory_cap) {
        std.debug.print("  ASSERTION FAILED: peak {d} bytes exceeds cap {d} bytes\n", .{
            counter.peak, stream_memory_cap,
        });
        std.process.exit(1);
    }
}

fn report(label: []const u8, fixture: []const u8, bytes: usize, samples: []u64) void {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const min = samples[0];
    const p50 = samples[samples.len / 2];
    // Nearest-rank p99: ceil(0.99 * n)-th order statistic.
    const p99 = samples[(samples.len * 99 - 1) / 100];
    const max = samples[samples.len - 1];

    const mbps = (@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)) /
        (@as(f64, @floatFromInt(p50)) / std.time.ns_per_s);

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s} {s}", .{ label, fixture }) catch label;

    var size_buf: [16]u8 = undefined;
    const size = std.fmt.bufPrint(&size_buf, "{Bi:.1}", .{bytes}) catch "?";

    std.debug.print("{s:<32} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10} {d:>9.1}\n", .{
        name, size, fmtNs(min), fmtNs(p50), fmtNs(p99), fmtNs(max), mbps,
    });
}

/// Format a nanosecond count with a unit suffix into a static buffer.
/// Each call reuses one of four rotating buffers so a single print
/// statement can hold up to four formatted values at once.
var ns_bufs: [4][16]u8 = undefined;
var ns_buf_idx: usize = 0;
fn fmtNs(ns: u64) []const u8 {
    const buf = &ns_bufs[ns_buf_idx];
    ns_buf_idx = (ns_buf_idx + 1) % ns_bufs.len;
    const f = @as(f64, @floatFromInt(ns));
    return if (ns < 1_000)
        std.fmt.bufPrint(buf, "{d} ns", .{ns}) catch "?"
    else if (ns < 1_000_000)
        std.fmt.bufPrint(buf, "{d:.2} us", .{f / 1_000.0}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d:.2} ms", .{f / 1_000_000.0}) catch "?";
}
