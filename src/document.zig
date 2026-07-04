//! Document model for JSON -- lossless parse, edit, and emit.
//!
//! Unlike `json.parse`, which throws away comments, formatting, and
//! original byte representations, `Document.parse` keeps the source
//! bytes alongside a structural node tree of byte ranges built from the
//! token stream. Every edit splices a minimal byte-range replacement
//! into the source, so emitting an unmodified `Document` reproduces the
//! input byte-for-byte and an edited one differs only where edited.
//!
//! All allocations go through the arena passed to `parse`; calling
//! `arena.deinit()` releases everything. There is no `Document.deinit`.
//! Each edit retains a full new source/tree generation in the arena, so
//! memory grows with edit count; for long-lived many-edit sessions,
//! periodically emit and re-parse into a fresh arena.
//!
//! ```zig
//! var doc = try json.Document.parse(arena, src, .{ .dialect = .jsonc });
//!
//! // Read existing values
//! const port = doc.getT(u16, "server.port").?;
//!
//! // Edit existing
//! try doc.set("server.port", @as(u16, 9999));
//!
//! // Insert new key (appended to its enclosing object)
//! try doc.setLiteral("server.tls", "true");
//!
//! // Remove
//! try doc.remove("dev.unused");
//!
//! // Emit
//! var aw: std.Io.Writer.Allocating = .init(gpa);
//! defer aw.deinit();
//! try doc.emit(&aw.writer);
//! ```
//!
//! Editing notes:
//! - `set` on an existing path replaces only the value's bytes; keys,
//!   separators, comments, and all surrounding formatting stay put.
//! - `set` on a missing leaf appends a new member to its enclosing
//!   object, matching the surrounding style: single-line objects get a
//!   `, "k": v` separator, multi-line objects get `,` + newline + the
//!   indentation inferred from the last sibling member. Only the leaf
//!   may be new; a missing intermediate container returns
//!   `error.PathNotFound`, and array elements can only be replaced,
//!   never created (an index leaf on a missing path is
//!   `error.PathNotFound` too).
//! - `remove` deletes the member or element together with its
//!   separator comma and the trivia between it and its neighbor;
//!   removing the only member collapses the container to `{}` / `[]`.
//! - Comment editing (`addCommentBefore`, `setTrailingComment`) is
//!   valid only for `.jsonc` documents; on strict-JSON documents both
//!   return `error.CommentsNotSupported`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const encoder = @import("encoder.zig");
const parser_mod = @import("parser.zig");
const tokenizer_mod = @import("tokenizer.zig");
const value_mod = @import("value.zig");

const Dialect = tokenizer_mod.Dialect;
const Token = tokenizer_mod.Token;
const Value = value_mod.Value;

pub const Error = error{
    PathNotFound,
    InvalidValue,
    CommentsNotSupported,
    /// Comment text contains a newline (which ends a // comment early)
    /// or the block terminator `*/` (which closes a /* */ comment early),
    /// either of which would inject live JSON into the document.
    InvalidComment,
    OutOfMemory,
    NestingTooDeep,
    JsonParseError,
};

/// Half-open byte range into the document's current `source`. Offsets are
/// usize, so any in-memory document is addressable without a size cap.
const Span = struct {
    start: usize,
    end: usize,

    fn bytes(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// One value in the source: byte range plus structure. Object members
/// and array elements hold child nodes; scalars are leaves.
///
/// `outer` is the full presentation envelope -- the bytes an edit
/// splices and emit reproduces. `content` is the inner bytes the value
/// decodes from and that matching/reads consult: for a JSON string token
/// `content` is `outer` minus the surrounding quotes (`content.start ==
/// outer.start + 1`); for every other scalar the two coincide
/// (`content.start == outer.start`).
const Node = struct {
    outer: Span,
    content: Span,
    data: union(enum) {
        scalar,
        object: std.ArrayList(Member),
        array: std.ArrayList(*Node),
    },

    /// The inner bytes a scalar decodes from / matches on (a string's
    /// content excludes its quotes).
    fn contentBytes(self: *const Node, source: []const u8) []const u8 {
        return self.content.bytes(source);
    }
};

/// One `"key": value` pair inside an object node.
///
/// `key.decoded` is the single canonical key identity -- the unescaped
/// bytes a lookup compares against, decoded once at build time so reads
/// and writes share one notion of "which key". `key.outer` is the
/// original key token (quotes included) so emit and anchoring reproduce
/// the source spelling.
const Member = struct {
    key: struct {
        decoded: []const u8,
        outer: Span,
    },
    value: *Node,
};

pub const Document = struct {
    arena: Allocator,
    source: []const u8,
    dialect: Dialect,
    max_depth: usize,
    root: *Node,
    parsed: Value,

    /// Parse a document, keeping the source bytes for lossless emit.
    /// All `ParseOptions` are honored by the validating parse (dialect,
    /// max_depth, errors, spans); `errors` and `spans` observe only this
    /// initial parse, not the internal re-parses that follow each edit.
    ///
    pub fn parse(arena: Allocator, input: []const u8, options: parser_mod.ParseOptions) !Document {
        const source = try arena.dupe(u8, input);
        const parsed = try parser_mod.parse(arena, source, options);
        return .{
            .arena = arena,
            .source = source,
            .dialect = options.dialect,
            .max_depth = options.max_depth,
            .root = try buildTree(arena, source, options.dialect, options.max_depth),
            .parsed = parsed,
        };
    }

    /// Look up a value by dotted path (syntax as `Value.get`). Returns
    /// null if absent.
    pub fn get(self: *const Document, path: []const u8) ?Value {
        return self.parsed.get(path);
    }

    /// Convenience: `self.get(path) != null`.
    pub fn has(self: *const Document, path: []const u8) bool {
        return self.get(path) != null;
    }

    /// Typed read by dotted path. Returns null on missing path,
    /// traversal through a non-container, type mismatch, or integer
    /// overflow. See `Value.getT` for the supported type set.
    pub fn getT(self: *const Document, comptime T: type, path: []const u8) ?T {
        return self.parsed.getT(T, path);
    }

    /// Headline setter. Comptime-dispatched on `@TypeOf(value)`:
    ///   - `Value`            -> setValue passthrough
    ///   - `bool`             -> .bool
    ///   - integer types      -> .integer
    ///   - float types        -> .float
    ///   - `[]const u8` or string literal -> .string (arena-duped)
    ///   - `null` / null optional -> .null
    /// Other types raise a compile error. The rendered bytes replace
    /// the existing value's span, or append a new member (see
    /// `setLiteral` for the append rules).
    pub fn set(self: *Document, path: []const u8, value: anytype) Error!void {
        const v = try valueFromAny(self.arena, @TypeOf(value), value);
        return self.setValue(path, v);
    }

    /// Set a value from a structured `Value`, rendered compactly via
    /// the canonical encoder.
    pub fn setValue(self: *Document, path: []const u8, value: Value) Error!void {
        const raw = try renderValue(self.arena, value);
        return self.setRaw(path, raw);
    }

    /// Set `path` to literal JSON source. `raw` must be a well-formed
    /// value in the document's dialect (e.g. `"\"x\""`, `42`, `true`,
    /// `[1, 2]`, `{"a": 1}`); it is validated by re-parsing and rejected
    /// with `error.InvalidValue` otherwise. Use `set` for native values;
    /// this is the escape hatch for splicing pre-formatted JSON.
    pub fn setLiteral(self: *Document, path: []const u8, raw: []const u8) Error!void {
        try self.validateLiteral(raw);
        return self.setRaw(path, try self.arena.dupe(u8, raw));
    }

    /// Remove a member or element. Returns `error.PathNotFound` if
    /// absent; the root value itself cannot be removed
    /// (`error.InvalidValue`).
    pub fn remove(self: *Document, path: []const u8) Error!void {
        const r = self.resolve(path) orelse return error.PathNotFound;
        const parent = r.parent orelse return error.InvalidValue;
        switch (parent.data) {
            .object => |members| {
                const items = members.items;
                if (items.len == 1) return self.applyEdit(parent.outer.start + 1, parent.outer.end - 1, "");
                if (r.index + 1 < items.len) {
                    return self.applyEdit(items[r.index].key.outer.start, items[r.index + 1].key.outer.start, "");
                }
                return self.applyEdit(items[r.index - 1].value.outer.end, items[r.index].value.outer.end, "");
            },
            .array => |elems| {
                const items = elems.items;
                if (items.len == 1) return self.applyEdit(parent.outer.start + 1, parent.outer.end - 1, "");
                if (r.index + 1 < items.len) {
                    return self.applyEdit(items[r.index].outer.start, items[r.index + 1].outer.start, "");
                }
                return self.applyEdit(items[r.index - 1].outer.end, items[r.index].outer.end, "");
            },
            .scalar => unreachable,
        }
    }

    /// Insert a `// text` comment line immediately before the value at
    /// `path`, indented like it. When the value does not start its own
    /// line, a `/* text */ ` block comment is inserted inline instead
    /// (a line comment would swallow the rest of the line). JSONC only.
    pub fn addCommentBefore(self: *Document, path: []const u8, text: []const u8) Error!void {
        if (self.dialect != .jsonc) return error.CommentsNotSupported;
        // A newline ends // comment early; */ closes /* */ early -- both inject live JSON.
        // Validate before touching the document so the source stays byte-identical on error.
        if (std.mem.indexOfAny(u8, text, "\n\r") != null) return error.InvalidComment;
        if (std.mem.indexOf(u8, text, "*/") != null) return error.InvalidComment;
        const r = self.resolve(path) orelse return error.PathNotFound;
        const anchor: usize = blk: {
            if (r.parent) |p| {
                if (p.data == .object) break :blk p.data.object.items[r.index].key.outer.start;
            }
            break :blk r.node.outer.start;
        };
        var line_start = anchor;
        while (line_start > 0 and self.source[line_start - 1] != '\n') line_start -= 1;
        const prefix = self.source[line_start..anchor];
        const ws_only = blk: {
            for (prefix) |c| {
                if (c != ' ' and c != '\t') break :blk false;
            }
            break :blk true;
        };
        const insertion = if (ws_only)
            try std.mem.concat(self.arena, u8, &.{ "// ", text, "\n", prefix })
        else
            try std.mem.concat(self.arena, u8, &.{ "/* ", text, " */ " });
        return self.applyEdit(anchor, anchor, insertion);
    }

    /// Set or replace the trailing comment after the value at `path`
    /// (after its separator comma when one follows). Pass `null` to
    /// remove an existing trailing comment. Uses `// text`, or
    /// `/* text */` when more content follows on the same line. JSONC
    /// only.
    pub fn setTrailingComment(self: *Document, path: []const u8, text: ?[]const u8) Error!void {
        if (self.dialect != .jsonc) return error.CommentsNotSupported;
        const r = self.resolve(path) orelse return error.PathNotFound;
        const src = self.source;

        // The trailing region is "[ws] [,] [ws] [comment]" on the value's
        // last line; the replacement starts after the comma (so the comma
        // survives) and covers any existing comment.
        var p: usize = r.node.outer.end;
        while (p < src.len and (src[p] == ' ' or src[p] == '\t')) p += 1;
        var insert_start: usize = r.node.outer.end;
        if (p < src.len and src[p] == ',') {
            p += 1;
            insert_start = p;
            while (p < src.len and (src[p] == ' ' or src[p] == '\t')) p += 1;
        }
        var region_end = insert_start;
        if (p + 1 < src.len and src[p] == '/' and src[p + 1] == '/') {
            var q = p;
            while (q < src.len and src[q] != '\n') q += 1;
            region_end = q;
        } else if (p + 1 < src.len and src[p] == '/' and src[p + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, p + 2, "*/") orelse return error.InvalidValue;
            region_end = close + 2;
        }

        const t = text orelse return self.applyEdit(insert_start, region_end, "");
        // Same injection guards as addCommentBefore -- validate before any edit.
        if (std.mem.indexOfAny(u8, t, "\n\r") != null) return error.InvalidComment;
        if (std.mem.indexOf(u8, t, "*/") != null) return error.InvalidComment;
        const line_clear = blk: {
            var q = region_end;
            while (q < src.len) : (q += 1) {
                if (src[q] == '\n') break :blk true;
                if (src[q] != ' ' and src[q] != '\t' and src[q] != '\r') break :blk false;
            }
            break :blk true;
        };
        const insertion = if (line_clear)
            try std.mem.concat(self.arena, u8, &.{ " // ", t })
        else
            try std.mem.concat(self.arena, u8, &.{ " /* ", t, " */" });
        return self.applyEdit(insert_start, region_end, insertion);
    }

    /// Write the (possibly modified) document. Byte-identical to the
    /// input when no edit was made.
    pub fn emit(self: *const Document, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(self.source);
    }

    // ----- edit machinery -----

    /// Splice `replacement` over `source[start..end)`, then revalidate
    /// and rebuild the node tree and parsed view against the new bytes.
    /// On a splice that would produce malformed JSON the document is
    /// left untouched and `error.InvalidValue` is returned.
    fn applyEdit(self: *Document, start: usize, end: usize, replacement: []const u8) Error!void {
        const new_source = try std.mem.concat(self.arena, u8, &.{
            self.source[0..start], replacement, self.source[end..],
        });
        const new_parsed = parser_mod.parse(self.arena, new_source, .{
            .dialect = self.dialect,
            .max_depth = self.max_depth,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NestingTooDeep => return error.NestingTooDeep,
            error.JsonParseError => return error.InvalidValue,
        };
        self.root = try buildTree(self.arena, new_source, self.dialect, self.max_depth);
        self.source = new_source;
        self.parsed = new_parsed;
    }

    fn setRaw(self: *Document, path: []const u8, raw: []const u8) Error!void {
        if (self.resolve(path)) |r| {
            return self.applyEdit(r.node.outer.start, r.node.outer.end, raw);
        }
        return self.insertNewMember(path, raw);
    }

    fn insertNewMember(self: *Document, path: []const u8, raw: []const u8) Error!void {
        const split = splitLeaf(path) orelse return error.PathNotFound;
        const pr = self.resolve(split.parent) orelse return error.PathNotFound;
        if (pr.node.data != .object) return error.InvalidValue;
        return self.appendMember(pr.node, split.leaf, raw);
    }

    fn appendMember(self: *Document, parent: *Node, key: []const u8, raw: []const u8) Error!void {
        const members = parent.data.object.items;
        const key_json = try renderValue(self.arena, .{ .string = key });
        if (members.len == 0) {
            // Replace the whole interior so `{}`, `{ }`, and `{\n}` all
            // collapse to `{"k": v}`.
            const text = try std.mem.concat(self.arena, u8, &.{ key_json, ": ", raw });
            return self.applyEdit(parent.outer.start + 1, parent.outer.end - 1, text);
        }
        const last = members[members.len - 1];
        const gap_start: usize = if (members.len >= 2)
            members[members.len - 2].value.outer.end
        else
            parent.outer.start + 1;
        const gap = self.source[gap_start..last.key.outer.start];
        const sep = try self.memberSeparator(gap, last.key.outer.start);
        const colon = self.colonStyle(last);
        const text = try std.mem.concat(self.arena, u8, &.{ sep, key_json, colon, raw });
        return self.applyEdit(last.value.outer.end, last.value.outer.end, text);
    }

    /// Style inference for an appended member: reuse the byte
    /// pattern around existing siblings. A gap containing a newline
    /// means a multi-line object: `,` + newline + the last member's
    /// indentation. A pure comma+spaces gap (only possible with two or
    /// more members) is reused verbatim, preserving tight `,` and loose
    /// `, ` styles alike. Anything else (single member, or trivia in
    /// the gap that must not be duplicated) falls back to `, `.
    fn memberSeparator(self: *Document, gap: []const u8, last_key_start: usize) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, gap, '\n') != null) {
            var ws_start = last_key_start;
            while (ws_start > 0 and (self.source[ws_start - 1] == ' ' or self.source[ws_start - 1] == '\t')) {
                ws_start -= 1;
            }
            return std.mem.concat(self.arena, u8, &.{ ",\n", self.source[ws_start..last_key_start] });
        }
        if (std.mem.indexOfScalar(u8, gap, ',') != null) {
            const clean = blk: {
                for (gap) |c| {
                    if (c != ',' and c != ' ' and c != '\t') break :blk false;
                }
                break :blk true;
            };
            if (clean) return gap;
        }
        return ", ";
    }

    /// The `: ` bytes of the last member, reused for the new one so
    /// `"k":v` and `"k": v` styles both carry over. Falls back to `: `
    /// when trivia sits between key and value.
    fn colonStyle(self: *const Document, m: Member) []const u8 {
        const cs = self.source[m.key.outer.end..m.value.outer.start];
        for (cs) |c| {
            if (c != ':' and c != ' ' and c != '\t') return ": ";
        }
        return cs;
    }

    fn validateLiteral(self: *const Document, raw: []const u8) Error!void {
        _ = parser_mod.parse(self.arena, raw, .{
            .dialect = self.dialect,
            .max_depth = self.max_depth,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
    }

    // ----- path resolution over the node tree -----

    const Resolved = struct {
        node: *Node,
        /// Containing object/array; null when `node` is the root.
        parent: ?*Node,
        /// Member or element index within `parent`.
        index: usize,
    };

    /// Walk `path` through the node tree (same syntax as `Value.get`:
    /// dotted keys, `[N]` indices, via `PathIterator`). Returns null on
    /// any missing segment or traversal through a scalar.
    fn resolve(self: *const Document, path: []const u8) ?Resolved {
        var cur = self.root;
        var parent: ?*Node = null;
        var index: usize = 0;
        var it = value_mod.PathIterator.init(path);
        while (it.next()) |segment| {
            switch (segment) {
                .key => |k| {
                    if (cur.data != .object) return null;
                    // Duplicate keys are last-wins (matching the parsed
                    // Value's ObjectMap): scan for the LAST member whose
                    // decoded key matches so reads and writes agree.
                    const found: ?usize = blk: {
                        var mi = cur.data.object.items.len;
                        while (mi > 0) {
                            mi -= 1;
                            if (std.mem.eql(u8, cur.data.object.items[mi].key.decoded, k)) break :blk mi;
                        }
                        break :blk null;
                    };
                    const mi = found orelse return null;
                    parent = cur;
                    index = mi;
                    cur = cur.data.object.items[mi].value;
                },
                .index => |idx| {
                    if (cur.data != .array) return null;
                    if (idx >= cur.data.array.items.len) return null;
                    parent = cur;
                    index = idx;
                    cur = cur.data.array.items[idx];
                },
                .raw => return null,
            }
        }
        return .{ .node = cur, .parent = parent, .index = index };
    }
};

const Split = struct { parent: []const u8, leaf: []const u8 };

/// Split a path into its enclosing-container path and final key
/// segment: "a.b[2].c" -> ("a.b[2]", "c"). Returns null when the leaf
/// is an array index (elements cannot be created, only replaced) or
/// empty. Iterating to exhaustion leaves `tail_start` at the byte
/// where the final segment's raw text begins; the parent is everything
/// before it minus a separator dot.
fn splitLeaf(path: []const u8) ?Split {
    if (path.len == 0 or path[path.len - 1] == ']' or path[path.len - 1] == '.') return null;
    var it = value_mod.PathIterator.init(path);
    while (it.next()) |_| {}
    const tail = path[it.tail_start..];
    // A `]` inside the tail still bounds the leaf even though lookups
    // treat it as key content, so a leaf key never contains `]`.
    if (std.mem.lastIndexOfScalar(u8, tail, ']')) |stray| {
        const cut = it.tail_start + stray + 1;
        return .{ .parent = path[0..cut], .leaf = path[cut..] };
    }
    const parent_end = if (it.tail_start > 0 and path[it.tail_start - 1] == '.')
        it.tail_start - 1
    else
        it.tail_start;
    return .{ .parent = path[0..parent_end], .leaf = path[it.tail_start..] };
}

/// Tokenize `source` (skipping comments) and build the node tree. The
/// caller guarantees `source` already passed the validating parser, so
/// any structural surprise here is `error.JsonParseError`.
fn buildTree(arena: Allocator, source: []const u8, dialect: Dialect, max_depth: usize) Error!*Node {
    // buildNode recurses one host stack frame per level; cap at the
    // stack-safe ceiling so a raised max_depth returns NestingTooDeep
    // rather than overflowing the stack.
    const limit = @min(max_depth, value_mod.recursive_depth_ceiling);
    var toks: std.ArrayList(Token) = .empty;
    var tz: tokenizer_mod.Tokenizer = .init(source, dialect);
    while (tz.next()) |t| {
        switch (t.kind) {
            .comment => continue,
            .invalid => return error.JsonParseError,
            else => try toks.append(arena, t),
        }
    }
    var i: usize = 0;
    const root = try buildNode(arena, source, toks.items, &i, 0, limit);
    if (i != toks.items.len) return error.JsonParseError;
    return root;
}

/// Build one node from the token slice at position `i`. `depth` is the
/// number of enclosing containers; opening a new container past `max_depth`
/// returns `error.NestingTooDeep` instead of recursing unboundedly.
fn buildNode(arena: Allocator, source: []const u8, toks: []const Token, i: *usize, depth: usize, max_depth: usize) Error!*Node {
    if (i.* >= toks.len) return error.JsonParseError;
    const t = toks[i.*];
    switch (t.kind) {
        .object_begin => {
            if (depth >= max_depth) return error.NestingTooDeep;
            i.* += 1;
            var members: std.ArrayList(Member) = .empty;
            while (true) {
                if (i.* >= toks.len) return error.JsonParseError;
                if (toks[i.*].kind == .object_end) break;
                const key_tok = toks[i.*];
                if (key_tok.kind != .string) return error.JsonParseError;
                i.* += 1;
                if (i.* >= toks.len or toks[i.*].kind != .colon) return error.JsonParseError;
                i.* += 1;
                const value = try buildNode(arena, source, toks, i, depth + 1, max_depth);
                const key_content = source[@intCast(key_tok.span.start + 1) .. @intCast(key_tok.span.end - 1)];
                try members.append(arena, .{
                    .key = .{
                        .decoded = try parser_mod.decodeStringContent(arena, key_content),
                        .outer = .{ .start = @intCast(key_tok.span.start), .end = @intCast(key_tok.span.end) },
                    },
                    .value = value,
                });
                if (i.* >= toks.len) return error.JsonParseError;
                switch (toks[i.*].kind) {
                    .comma => i.* += 1, // trailing comma (jsonc): next is close
                    .object_end => {},
                    else => return error.JsonParseError,
                }
            }
            const close = toks[i.*];
            i.* += 1;
            return makeContainer(arena, @intCast(t.span.start), @intCast(close.span.end), .{ .object = members });
        },
        .array_begin => {
            if (depth >= max_depth) return error.NestingTooDeep;
            i.* += 1;
            var elems: std.ArrayList(*Node) = .empty;
            while (true) {
                if (i.* >= toks.len) return error.JsonParseError;
                if (toks[i.*].kind == .array_end) break;
                const elem = try buildNode(arena, source, toks, i, depth + 1, max_depth);
                try elems.append(arena, elem);
                if (i.* >= toks.len) return error.JsonParseError;
                switch (toks[i.*].kind) {
                    .comma => i.* += 1,
                    .array_end => {},
                    else => return error.JsonParseError,
                }
            }
            const close = toks[i.*];
            i.* += 1;
            return makeContainer(arena, @intCast(t.span.start), @intCast(close.span.end), .{ .array = elems });
        },
        .string => {
            i.* += 1;
            // A string token's outer envelope includes both quotes; its
            // content is the bytes between them.
            return makeNode(arena, .{
                .outer = .{ .start = @intCast(t.span.start), .end = @intCast(t.span.end) },
                .content = .{ .start = @intCast(t.span.start + 1), .end = @intCast(t.span.end - 1) },
                .data = .scalar,
            });
        },
        .number, .literal_true, .literal_false, .literal_null => {
            i.* += 1;
            return makeNode(arena, .{
                .outer = .{ .start = @intCast(t.span.start), .end = @intCast(t.span.end) },
                .content = .{ .start = @intCast(t.span.start), .end = @intCast(t.span.end) },
                .data = .scalar,
            });
        },
        else => return error.JsonParseError,
    }
}

fn makeNode(arena: Allocator, node: Node) Error!*Node {
    const p = try arena.create(Node);
    p.* = node;
    return p;
}

/// Build a container node whose outer envelope spans the open and close
/// delimiters; a container's content coincides with its outer.
fn makeContainer(arena: Allocator, start: usize, end: usize, data: @FieldType(Node, "data")) Error!*Node {
    return makeNode(arena, .{
        .outer = .{ .start = start, .end = end },
        .content = .{ .start = start, .end = end },
        .data = data,
    });
}

/// Render a `Value` as compact JSON bytes via the canonical encoder.
fn renderValue(arena: Allocator, value: Value) Error![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    encoder.encode(&aw.writer, value) catch |err| switch (err) {
        // The allocating writer fails a write only on allocation failure.
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.UnrepresentableFloat, error.NestingTooDeep => return error.InvalidValue,
    };
    return arena.dupe(u8, aw.written());
}

/// Convert a native Zig value into a `Value`, comptime-dispatched on
/// `@TypeOf(value)`. Used by `Document.set`. Supported: Value
/// passthrough, bool, integer, float, `[]const u8`, string literal
/// pointers, `null`, optionals of the above. Unsupported types
/// compile-error.
///
/// Integer range: the `.integer` variant holds i128, so any integer type
/// that fits in i128 round-trips losslessly. A `u128` value above
/// `std.math.maxInt(i128)` cannot be cast to i128 and returns
/// `error.InvalidValue`. For those values the escape hatch is
/// `setLiteral(path, "340282366920938463463374607431768211456")` (or
/// whatever the decimal text is), which splices the exact numeric string
/// without going through `.integer`.
fn valueFromAny(arena: Allocator, comptime T: type, value: T) Error!Value {
    if (T == Value) return value;
    if (T == @TypeOf(null)) return .null;
    return switch (@typeInfo(T)) {
        .bool => .{ .bool = value },
        .int => .{ .integer = std.math.cast(i128, value) orelse return error.InvalidValue },
        .comptime_int => .{ .integer = value },
        .float => .{ .float = @floatCast(value) },
        .comptime_float => .{ .float = value },
        .optional => |o| if (value) |inner| try valueFromAny(arena, o.child, inner) else .null,
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8 and p.is_const) {
                break :blk .{ .string = try arena.dupe(u8, value) };
            }
            if (p.size == .one and p.is_const) {
                const child_info = @typeInfo(p.child);
                if (child_info == .array and child_info.array.child == u8) {
                    const as_slice: []const u8 = value;
                    break :blk .{ .string = try arena.dupe(u8, as_slice) };
                }
            }
            @compileError("Document.set: only []const u8 / string literal supported, got " ++ @typeName(T));
        },
        else => @compileError("Document.set: unsupported type " ++ @typeName(T)),
    };
}

// ----- tests -----

test "unmodified emit is byte-identical incl jsonc trivia" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{\n  // port comment\n  \"port\": 8080, /* t */\n  \"big\": 1e2,\n}\n";
    var doc = try Document.parse(a, src, .{ .dialect = .jsonc });
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "set is minimal diff" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{ \"x\": 1, \"y\": 2 }", .{});
    try doc.set("x", @as(u16, 99));
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("{ \"x\": 99, \"y\": 2 }", aw.written());
}

test "set new key appends; remove deletes; setLiteral splices" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\"a\": 1}", .{});
    try doc.set("b", true);
    try doc.setLiteral("c", "[1, 2]");
    try doc.remove("a");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("{\"b\": true, \"c\": [1, 2]}", aw.written());
}

test "comment editing in jsonc" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\n  \"p\": 1\n}", .{ .dialect = .jsonc });
    try doc.addCommentBefore("p", "the port");
    try doc.setTrailingComment("p", "keep");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("{\n  // the port\n  \"p\": 1 // keep\n}", aw.written());
}

test "getT reads through document" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "{\"server\": {\"port\": 1}}", .{});
    try std.testing.expectEqual(@as(u16, 1), doc.getT(u16, "server.port").?);
}

fn emitToString(a: Allocator, doc: *const Document) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    return a.dupe(u8, aw.written());
}

test "nested set through objects and array index" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\"a\": {\"b\": [0, 1, {\"c\": 5}]}}", .{});
    try doc.set("a.b[2].c", @as(u8, 9));
    try testing.expectEqualStrings("{\"a\": {\"b\": [0, 1, {\"c\": 9}]}}", try emitToString(a, &doc));
}

test "set in arrays by index" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\"a\": [1, 2, 3]}", .{});
    try doc.set("a[1]", @as(i64, 9));
    try testing.expectEqualStrings("{\"a\": [1, 9, 3]}", try emitToString(a, &doc));
}

test "setLiteral preserves surrounding trivia" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{\n  // keep me\n  \"x\": /* pre */ 1, // tail\n}";
    var doc = try Document.parse(a, src, .{ .dialect = .jsonc });
    try doc.setLiteral("x", "42");
    try testing.expectEqualStrings(
        "{\n  // keep me\n  \"x\": /* pre */ 42, // tail\n}",
        try emitToString(a, &doc),
    );
}

test "remove first, middle, last member of multi-line object" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}";

    var first = try Document.parse(a, src, .{});
    try first.remove("a");
    try testing.expectEqualStrings("{\n  \"b\": 2,\n  \"c\": 3\n}", try emitToString(a, &first));

    var middle = try Document.parse(a, src, .{});
    try middle.remove("b");
    try testing.expectEqualStrings("{\n  \"a\": 1,\n  \"c\": 3\n}", try emitToString(a, &middle));

    var last = try Document.parse(a, src, .{});
    try last.remove("c");
    try testing.expectEqualStrings("{\n  \"a\": 1,\n  \"b\": 2\n}", try emitToString(a, &last));
}

test "remove first, middle, last element of array" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "[1, 2, 3]";

    var first = try Document.parse(a, src, .{});
    try first.remove("[0]");
    try testing.expectEqualStrings("[2, 3]", try emitToString(a, &first));

    var middle = try Document.parse(a, src, .{});
    try middle.remove("[1]");
    try testing.expectEqualStrings("[1, 3]", try emitToString(a, &middle));

    var last = try Document.parse(a, src, .{});
    try last.remove("[2]");
    try testing.expectEqualStrings("[1, 2]", try emitToString(a, &last));
}

test "remove only member collapses container" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    var obj = try Document.parse(a, "{ \"only\": 1 }", .{});
    try obj.remove("only");
    try testing.expectEqualStrings("{}", try emitToString(a, &obj));

    var arr = try Document.parse(a, "{\"a\": [ 1 ]}", .{});
    try arr.remove("a[0]");
    try testing.expectEqualStrings("{\"a\": []}", try emitToString(a, &arr));
}

test "raw number text preserved when editing a sibling" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{ \"big\": 1e2, \"x\": 1 }", .{});
    try doc.set("x", @as(i64, 2));
    try testing.expectEqualStrings("{ \"big\": 1e2, \"x\": 2 }", try emitToString(a, &doc));
}

test "multi-line append matches sibling indentation" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\n  \"a\": 1,\n  \"b\": 2\n}", .{});
    try doc.set("c", @as(i64, 3));
    try testing.expectEqualStrings("{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}", try emitToString(a, &doc));
}

test "multi-line append preserves jsonc trailing comma" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\n  \"a\": 1,\n}", .{ .dialect = .jsonc });
    try doc.set("b", @as(i64, 2));
    try testing.expectEqualStrings("{\n  \"a\": 1,\n  \"b\": 2,\n}", try emitToString(a, &doc));
}

test "append into tight single-line object reuses tight separator" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\"a\":1,\"b\":2}", .{});
    try doc.set("c", @as(i64, 3));
    try testing.expectEqualStrings("{\"a\":1,\"b\":2,\"c\":3}", try emitToString(a, &doc));
}

test "append into empty object" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{}", .{});
    try doc.set("k", "v");
    try testing.expectEqualStrings("{\"k\": \"v\"}", try emitToString(a, &doc));
}

test "set with missing intermediate path errors" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "{\"a\": 1}", .{});
    try testing.expectError(error.PathNotFound, doc.set("missing.leaf", true));
    // Path through a scalar is a type error, not a missing path.
    try testing.expectError(error.InvalidValue, doc.set("a.leaf", true));
}

test "comment ops error on strict-json documents" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "{\"p\": 1}", .{});
    try testing.expectError(error.CommentsNotSupported, doc.addCommentBefore("p", "x"));
    try testing.expectError(error.CommentsNotSupported, doc.setTrailingComment("p", "x"));
}

test "comment injection via newline is rejected atomically" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{\n  \"p\": 1,\n  \"q\": 2\n}";
    var doc = try Document.parse(a, src, .{ .dialect = .jsonc });
    // setTrailingComment: newline would terminate // and expose the rest as live JSON.
    try testing.expectError(error.InvalidComment, doc.setTrailingComment("p", "hi\n  \"z\": 99,"));
    try testing.expectEqualStrings(src, try emitToString(a, &doc));
    try testing.expect(!doc.has("z"));
    // addCommentBefore: same attack vector.
    try testing.expectError(error.InvalidComment, doc.addCommentBefore("p", "note\n  \"injected\": 42,"));
    try testing.expectEqualStrings(src, try emitToString(a, &doc));
    try testing.expect(!doc.has("injected"));
}

test "comment injection via block terminator is rejected atomically" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "{ \"p\": 1 }";
    var doc = try Document.parse(a, src, .{ .dialect = .jsonc });
    // */ in the text would close the /* block comment and expose trailing content.
    try testing.expectError(error.InvalidComment, doc.setTrailingComment("p", "evil */ , \"z\": 2 /* x"));
    try testing.expectEqualStrings(src, try emitToString(a, &doc));
    try testing.expect(!doc.has("z"));
    try testing.expectError(error.InvalidComment, doc.addCommentBefore("p", "x */ y"));
    try testing.expectEqualStrings(src, try emitToString(a, &doc));
}

test "valid single-line comments pass injection guard" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\n  \"p\": 1\n}", .{ .dialect = .jsonc });
    try doc.addCommentBefore("p", "safe comment");
    try doc.setTrailingComment("p", "also safe");
    const result = try emitToString(a, &doc);
    try testing.expectEqualStrings("{\n  // safe comment\n  \"p\": 1 // also safe\n}", result);
}

test "remove missing path errors" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "{\"a\": 1}", .{});
    try testing.expectError(error.PathNotFound, doc.remove("nope"));
    try testing.expectError(error.PathNotFound, doc.remove("a[0]"));
}

test "set on array index out of bounds errors" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "{\"a\": [1, 2]}", .{});
    try testing.expectError(error.PathNotFound, doc.set("a[2]", @as(i64, 3)));
}

test "setLiteral rejects malformed literals" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "{\"x\": 1}", .{});
    try testing.expectError(error.InvalidValue, doc.setLiteral("x", "not json"));
    try testing.expectError(error.InvalidValue, doc.setLiteral("x", "1,2"));
    // Strict-json documents reject jsonc-only literal syntax.
    try testing.expectError(error.InvalidValue, doc.setLiteral("x", "[1, 2,]"));
}

test "multiple sets on the same path: last wins" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\"x\": 1}", .{});
    try doc.set("x", @as(i64, 2));
    try doc.setLiteral("x", "[true]");
    try doc.set("x", @as(i64, 3));
    try testing.expectEqualStrings("{\"x\": 3}", try emitToString(a, &doc));
    try testing.expectEqual(@as(i64, 3), doc.getT(i64, "x").?);
}

test "trailing comment is replaced, not stacked" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\n  \"p\": 1, // old\n  \"q\": 2\n}", .{ .dialect = .jsonc });
    try doc.setTrailingComment("p", "new");
    try testing.expectEqualStrings("{\n  \"p\": 1, // new\n  \"q\": 2\n}", try emitToString(a, &doc));
    try doc.setTrailingComment("p", null);
    try testing.expectEqualStrings("{\n  \"p\": 1,\n  \"q\": 2\n}", try emitToString(a, &doc));
}

test "trailing comment uses block form when content follows on the line" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{ \"p\": 1 }", .{ .dialect = .jsonc });
    try doc.setTrailingComment("p", "note");
    try testing.expectEqualStrings("{ \"p\": 1 /* note */ }", try emitToString(a, &doc));
}

test "nasty jsonc fixture: deep nesting, comments, trailing commas" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        "{\n" ++
        "  // config\n" ++
        "  \"server\": {\n" ++
        "    /* nested */\n" ++
        "    \"listen\": [\n" ++
        "      { \"port\": 8080, },\n" ++
        "      // more\n" ++
        "      { \"port\": 9090 },\n" ++
        "    ],\n" ++
        "  },\n" ++
        "  \"big\": 1e2,\n" ++
        "}\n";
    var doc = try Document.parse(a, src, .{ .dialect = .jsonc });
    try testing.expectEqualStrings(src, try emitToString(a, &doc));

    try doc.set("server.listen[0].port", @as(u16, 1234));
    const expected =
        "{\n" ++
        "  // config\n" ++
        "  \"server\": {\n" ++
        "    /* nested */\n" ++
        "    \"listen\": [\n" ++
        "      { \"port\": 1234, },\n" ++
        "      // more\n" ++
        "      { \"port\": 9090 },\n" ++
        "    ],\n" ++
        "  },\n" ++
        "  \"big\": 1e2,\n" ++
        "}\n";
    try testing.expectEqualStrings(expected, try emitToString(a, &doc));
    try testing.expectEqual(@as(u16, 1234), doc.getT(u16, "server.listen[0].port").?);
}

test "scalar root document round-trips and edits" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "  42 ", .{});
    try testing.expectEqualStrings("  42 ", try emitToString(a, &doc));
    try doc.set("", @as(i64, 7));
    try testing.expectEqualStrings("  7 ", try emitToString(a, &doc));
    try testing.expectError(error.InvalidValue, doc.remove(""));
}

test "set dispatches across native types" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{}", .{});
    try doc.set("i", @as(i64, -5));
    try doc.set("f", @as(f64, 1.5));
    try doc.set("s", "hey");
    try doc.set("b", false);
    try doc.set("n", null);
    try doc.setValue("v", .{ .integer = 42 });
    try testing.expectEqual(@as(i64, -5), doc.getT(i64, "i").?);
    try testing.expectEqual(@as(f64, 1.5), doc.getT(f64, "f").?);
    try testing.expectEqualStrings("hey", doc.getT([]const u8, "s").?);
    try testing.expectEqual(false, doc.getT(bool, "b").?);
    try testing.expect(doc.get("n").? == .null);
    try testing.expectEqual(@as(i64, 42), doc.getT(i64, "v").?);
    try testing.expect(doc.has("i"));
    try testing.expect(!doc.has("missing"));
}

test "Document.parse honors ParseOptions diagnostics" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(parser_mod.Diagnostic) = .empty;
    try testing.expectError(
        error.JsonParseError,
        Document.parse(a, "{\"x\": }", .{ .errors = &errs }),
    );
    try testing.expect(errs.items.len > 0);
}

test "duplicate key: reads, set, and remove all target the last occurrence" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\"a\":1,\"a\":2}", .{});
    // Read sees last-wins (matches the parsed Value).
    try testing.expectEqual(@as(i64, 2), doc.getT(i64, "a").?);

    // set edits the LAST occurrence in place.
    try doc.set("a", @as(i64, 9));
    try testing.expectEqualStrings("{\"a\":1,\"a\":9}", try emitToString(a, &doc));
    try testing.expectEqual(@as(i64, 9), doc.getT(i64, "a").?);

    // remove deletes the LAST occurrence; a duplicate genuinely remains so
    // has() stays true and read falls back to the surviving earlier copy.
    try doc.remove("a");
    try testing.expectEqualStrings("{\"a\":1}", try emitToString(a, &doc));
    try testing.expect(doc.has("a"));
    try testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);

    // A second remove clears the key entirely.
    try doc.remove("a");
    try testing.expectEqualStrings("{}", try emitToString(a, &doc));
    try testing.expect(!doc.has("a"));
}

test "escaped key: set edits in place using the decoded identity" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Source spells the key "a" which decodes to "a".
    var doc = try Document.parse(a, "{\"\\u0061\":1}", .{});
    try testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
    try testing.expect(doc.has("a"));

    // set targets the decoded key and edits the value in place, preserving
    // the original key spelling -- no appended duplicate.
    try doc.set("a", @as(i64, 2));
    try testing.expectEqualStrings("{\"\\u0061\":2}", try emitToString(a, &doc));
    try testing.expectEqual(@as(i64, 2), doc.getT(i64, "a").?);
    try testing.expectEqual(@as(usize, 1), doc.root.data.object.items.len);
}

test "quoted-string value: set replaces the whole token incl quotes" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "{\"x\":\"5\"}", .{});
    try doc.set("x", @as(i64, 5));
    try testing.expectEqualStrings("{\"x\":5}", try emitToString(a, &doc));
    try testing.expectEqual(@as(i64, 5), doc.getT(i64, "x").?);
}

test "invariant: resolve content matches Value.get; outer splice is a no-op" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // dup key (last-wins), escaped key ("b"), quoted-string value, nested.
    const src = "{\"a\":1,\"a\":2,\"\\u0062\":\"5\",\"n\":{\"x\":3}}";
    var doc = try Document.parse(a, src, .{});
    const paths = [_][]const u8{ "a", "b", "n.x" };
    for (paths) |p| {
        const r = doc.resolve(p).?;
        const want = doc.get(p).?;
        // The resolved node's outer bytes re-parse to the same logical
        // value the parsed view reports for this path: resolve() and the
        // Value agree on which node a path designates, dups included.
        const reparsed = try parser_mod.parse(a, r.node.outer.bytes(doc.source), .{});
        switch (want) {
            .integer => |n| try testing.expectEqual(n, reparsed.integer),
            .string => |s| try testing.expectEqualStrings(s, reparsed.string),
            else => unreachable,
        }
        // A string scalar's content (quotes stripped) decodes to the value.
        if (want == .string) {
            const decoded = try parser_mod.decodeStringContent(a, r.node.contentBytes(doc.source));
            try testing.expectEqualStrings(want.string, decoded);
        }
    }
    // Splicing each resolved node's outer span with its own original bytes
    // is a no-op: an unmodified emit stays byte-identical.
    try testing.expectEqualStrings(src, try emitToString(a, &doc));
}

test "buildNode depth bound: over-depth errors cleanly, normal depth succeeds" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // Build JSON nested one level deeper than the cap (max_depth=2, depth=3).
    // Document.parse runs the capped parser first; NestingTooDeep comes from
    // that gate. The same cap is now forwarded into buildNode so it would also
    // fire there -- the guard is explicit and local, not implicit from the
    // prior parse.
    const over = "[[[\"x\"]]]"; // depth 3: array > array > array > scalar
    try testing.expectError(
        error.NestingTooDeep,
        Document.parse(a, over, .{ .max_depth = 2 }),
    );

    // A document exactly at the cap must succeed.
    const at_cap = "[[\"x\"]]"; // depth 2: array > array > scalar
    var doc = try Document.parse(a, at_cap, .{ .max_depth = 2 });
    try testing.expectEqualStrings("x", doc.getT([]const u8, "[0][0]").?);
}

test "Document.parse: raised max_depth never overflows the stack" {
    // 200k levels of '[' with max_depth raised to a million. Both the
    // validating parse and buildNode cap at recursive_depth_ceiling, so this
    // returns NestingTooDeep without recursing past the ceiling -- no SIGSEGV.
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const deep = try a.alloc(u8, 200_000);
    @memset(deep, '[');
    try testing.expectError(error.NestingTooDeep, Document.parse(a, deep, .{ .max_depth = 1_000_000 }));
}
