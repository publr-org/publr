//! The GROQ texts a plugin prepares (`publr.query.prepare(...)`), read by the build beside
//! its doc comments: a string, the lines of one, or `@embedFile` of a file in the plugin's
//! folder. The docs module carries them as `queries`, so the plugin checks parse each one:
//! `publr plugin check` and `plugin build`, the install gate (from the manifest), and boot
//! for compiled-in plugins. A text the build cannot see (made at comptime) is left to its
//! first run.
const std = @import("std");
const File = @import("doc_reader.zig").File;

pub const queries_max: u32 = 256;

/// One prepared query: where it is and its text, as the manifest carries it.
pub const Query = @import("../../model/sandboxed_plugin.zig").Query;

/// What `read` could not follow: an `@embedFile` naming a file the plugin's folder lacks.
pub const Missing = struct {
    path: []const u8,
    line: u32,
    embedded: []const u8,
};

/// Every prepared text in `file`, appended to `out`; an embedded file not among `files`
/// to `missing`.
pub fn read(
    arena: std.mem.Allocator,
    file: File,
    files: []const File,
    out: *std.ArrayList(Query),
    missing: *std.ArrayList(Missing),
) error{ OutOfMemory, TooManyQueries }!void {
    std.debug.assert(file.text.len < std.math.maxInt(u32));
    std.debug.assert(out.items.len <= queries_max);

    var tokenizer = std.zig.Tokenizer.init(file.text);
    var last: [3]std.zig.Token = undefined;
    var seen: u32 = 0;

    while (true) {
        const token = tokenizer.next();

        if (token.tag == .eof) {
            return;
        }

        const called = token.tag == .l_paren and seen >= 3 and
            last[0].tag == .identifier and eql(file, last[0], "query") and
            last[1].tag == .period and
            last[2].tag == .identifier and eql(file, last[2], "prepare");

        last[0] = last[1];
        last[1] = last[2];
        last[2] = token;
        seen += 1;

        if (!called) {
            continue;
        }

        const line: u32 = @intCast(std.mem.count(u8, file.text[0..token.loc.start], "\n") + 1);
        const text = try argument(arena, &tokenizer, file, files, line, missing) orelse continue;

        if (out.items.len == queries_max) {
            return error.TooManyQueries;
        }

        try out.append(arena, .{
            .path = file.path,
            .line = line,
            .text = text,
        });
    }
}

fn eql(file: File, token: std.zig.Token, word: []const u8) bool {
    return std.mem.eql(u8, file.text[token.loc.start..token.loc.end], word);
}

/// The text a call's first argument spells; null for one the build cannot read.
fn argument(
    arena: std.mem.Allocator,
    tokenizer: *std.zig.Tokenizer,
    file: File,
    files: []const File,
    line: u32,
    missing: *std.ArrayList(Missing),
) error{OutOfMemory}!?[]const u8 {
    std.debug.assert(line > 0);

    var token = tokenizer.next();

    switch (token.tag) {
        .string_literal => return literal(arena, file, token),
        .multiline_string_literal_line => {
            var text: std.ArrayList(u8) = .empty;

            while (token.tag == .multiline_string_literal_line) : (token = tokenizer.next()) {
                const raw = file.text[token.loc.start..token.loc.end];
                const content = std.mem.trimEnd(u8, raw[2..], "\r\n");

                if (text.items.len > 0) {
                    try text.append(arena, '\n');
                }

                try text.appendSlice(arena, content);
            }

            return text.items;
        },
        .builtin => {
            if (!eql(file, token, "@embedFile") or tokenizer.next().tag != .l_paren) {
                return null;
            }

            const named = tokenizer.next();

            if (named.tag != .string_literal) {
                return null;
            }

            const relative = try literal(arena, file, named) orelse return null;
            const dir = std.fs.path.dirnamePosix(file.path) orelse "";
            const path = try joined(arena, dir, relative);

            for (files) |each| {
                if (std.mem.eql(u8, each.path, path)) {
                    return each.text;
                }
            }

            try missing.append(arena, .{
                .path = file.path,
                .line = line,
                .embedded = relative,
            });

            return null;
        },
        else => return null,
    }
}

fn literal(
    arena: std.mem.Allocator,
    file: File,
    token: std.zig.Token,
) error{OutOfMemory}!?[]const u8 {
    std.debug.assert(token.tag == .string_literal);

    const raw = file.text[token.loc.start..token.loc.end];

    return std.zig.string_literal.parseAlloc(arena, raw) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// `dir/relative` with `.` and `..` taken out, as the plugin's files are named.
fn joined(
    arena: std.mem.Allocator,
    dir: []const u8,
    relative: []const u8,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(relative.len > 0);

    var parts: std.ArrayList([]const u8) = .empty;
    var all = std.mem.splitScalar(u8, dir, '/');

    while (all.next()) |part| {
        try parts.append(arena, part);
    }

    var given = std.mem.splitScalar(u8, relative, '/');

    while (given.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            _ = parts.pop();
        } else if (part.len > 0 and !std.mem.eql(u8, part, ".")) {
            try parts.append(arena, part);
        }
    }

    var kept: std.ArrayList([]const u8) = .empty;

    for (parts.items) |part| {
        if (part.len > 0) {
            try kept.append(arena, part);
        }
    }

    return std.mem.join(arena, "/", kept.items);
}

/// The texts a plugin's docs module carries; none for a plugin bound without them.
pub fn of(comptime Docs: type) []const Query {
    comptime {
        var list: []const Query = &.{};

        if (!@hasDecl(Docs, "queries")) {
            return list;
        }

        std.debug.assert(Docs.queries.len <= queries_max);

        for (0..Docs.queries.len) |index| {
            const query = Docs.queries[index];

            list = list ++ &[_]Query{.{
                .path = query.path,
                .line = query.line,
                .text = query.text,
            }};
        }

        const done = list;

        return done;
    }
}

/// The texts as a declaration the docs module carries: `queries`.
pub fn source(arena: std.mem.Allocator, queries: []const Query) error{OutOfMemory}![]const u8 {
    std.debug.assert(queries.len <= queries_max);

    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(arena, "\npub const queries = .{\n");

    for (queries) |query| {
        try out.print(arena, "    .{{ .path = \"{f}\", .line = {d}, .text = \"{f}\" }},\n", .{
            std.zig.fmtString(query.path),
            query.line,
            std.zig.fmtString(query.text),
        });
    }

    try out.appendSlice(arena, "};\n");

    return out.items;
}

test "prepared texts: a string, lines of one, a file beside it; a missing file named" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const main: File = .{
        .path = "operations/count.zig",
        .text =
        \\const counted = publr.query.prepare("count(*[_type == \"shelf.item\"])", .{});
        \\const lines = publr.query.prepare(
        \\    \\*[_type == "post"]
        \\    \\{ title }
        \\, .{});
        \\const kept = publr.query.prepare(@embedFile("../queries/notes.groq"), .{});
        \\const gone = publr.query.prepare(@embedFile("nowhere.groq"), .{});
        \\const made = publr.query.prepare(text, .{});
        ,
    };
    const files = [_]File{ main, .{
        .path = "queries/notes.groq",
        .text = "*[_type == \"note\"]",
    } };
    var out: std.ArrayList(Query) = .empty;
    var missing: std.ArrayList(Missing) = .empty;

    try read(arena, main, &files, &out, &missing);

    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("count(*[_type == \"shelf.item\"])", out.items[0].text);
    try std.testing.expectEqualStrings("*[_type == \"post\"]\n{ title }", out.items[1].text);
    try std.testing.expectEqual(@as(u32, 2), out.items[1].line);
    try std.testing.expectEqualStrings("*[_type == \"note\"]", out.items[2].text);
    try std.testing.expectEqual(@as(usize, 1), missing.items.len);
    try std.testing.expectEqualStrings("nowhere.groq", missing.items[0].embedded);

    const written = try source(arena, out.items[0..1]);

    try std.testing.expect(std.mem.indexOf(u8, written, ".line = 1") != null);
}
