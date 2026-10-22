//! The words of a plugin are its doc comments, and the compiler cannot see comments, so the
//! build reads them first: every `//!` and `///` in a plugin's files, keyed the way Zig names
//! what they document (`operations.answer.In.page`), so comptime finds a field's words by
//! `@typeName`. The same reader serves the compiled-in build and `publr plugin build`.
const std = @import("std");
const Ast = std.zig.Ast;
const doc_imports = @import("doc_imports.zig");

pub const Entry = struct {
    key: []const u8,
    text: []const u8,
    /// Words kept under another key, in another file: `generated` takes them from there.
    alias: []const u8 = "",
};

pub const entries_max: u32 = 4096;
pub const files_max: u32 = 512;
pub const file_bytes_max: u32 = 1 << 20;
pub const depth_max: u32 = 8;
pub const key_len_max: u32 = 256;

const Pending = struct {
    node: Ast.Node.Index,
    key: []const u8,
    depth: u32,
};

/// One file of a plugin: its path under the plugin's folder and its text.
pub const File = struct {
    path: []const u8,
    text: [:0]const u8,
};

pub const Placed = @import("checks.zig").Failures.Placed;

/// A plugin's docs module and what its checks found.
pub const Source = struct {
    source: []const u8,
    problems: []const Placed,
};

/// Every doc comment in a plugin's files and the secrets its strings write, as the Zig source
/// of its docs module, with every plugin check's problem beside its file: the one reading
/// the compiled-in build and `publr plugin build` both run.
pub fn source_of(arena: std.mem.Allocator, files: []const File) !Source {
    const checks = @import("checks.zig");
    const written_secrets = @import("written_secrets.zig");

    std.debug.assert(files.len <= files_max);

    var entries: std.ArrayList(Entry) = .empty;
    var written: std.ArrayList([]const u8) = .empty;
    var problems: std.ArrayList(Placed) = .empty;
    var failures: checks.Failures = .{};

    for (files) |file| {
        var found: std.ArrayList(checks.Problem) = .empty;

        try read(arena, try file_key(arena, file.path), file.text, &entries);
        try written_secrets.read(arena, file.text, &written);
        try checks.check(arena, file.path, file.text, &found);
        try failures.read(arena, file.path, file.text);

        for (found.items) |problem| {
            try problems.append(arena, .{
                .path = file.path,
                .problem = problem,
            });
        }
    }

    try problems.appendSlice(arena, try failures.problems(arena));

    const words = try generated(arena, entries.items);
    const secrets = try written_secrets.source(arena, written.items);

    return .{
        .source = try std.mem.concat(arena, u8, &.{ words, secrets }),
        .problems = problems.items,
    };
}

/// `operations/answer.zig` as Zig names it: `operations.answer`.
pub fn file_key(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(std.mem.endsWith(u8, path, ".zig"));

    const stem = path[0 .. path.len - ".zig".len];
    const key = try arena.dupe(u8, stem);

    for (key) |*byte| {
        if (byte.* == '/' or byte.* == '\\') {
            byte.* = '.';
        }
    }

    return key;
}

/// Every doc comment in one file, appended to `out`: the file's `//!` under its own key, each
/// `///` under the path of the declaration or field it documents. A file that does not parse
/// adds nothing; the compiler reports it.
pub fn read(
    arena: std.mem.Allocator,
    key: []const u8,
    text: [:0]const u8,
    out: *std.ArrayList(Entry),
) !void {
    std.debug.assert(key.len > 0 and key.len <= key_len_max);
    std.debug.assert(text.len < std.math.maxInt(u32));

    var tree = try Ast.parse(arena, text, .zig);

    if (tree.errors.len > 0) {
        return;
    }

    const file_words = try container_doc(arena, &tree);

    if (file_words) |words| {
        try add(arena, out, key, words);
    }

    try collect(arena, &tree, tree.rootDecls(), key, out);
    try collect_definitions(arena, &tree, file_words, out);
    try collect_hooks(arena, &tree, key, out);
}

/// The members' own words, then those of every container nested under them.
fn collect(
    arena: std.mem.Allocator,
    tree: *const Ast,
    roots: []const Ast.Node.Index,
    key: []const u8,
    out: *std.ArrayList(Entry),
) !void {
    std.debug.assert(key.len > 0);
    std.debug.assert(tree.errors.len == 0);

    var pending: std.ArrayList(Pending) = .empty;

    try pending.append(arena, .{
        .node = .root,
        .key = key,
        .depth = 0,
    });

    while (pending.pop()) |item| {
        var buffer: [2]Ast.Node.Index = undefined;
        const members = if (item.node == .root) roots else members: {
            const container = tree.fullContainerDecl(&buffer, item.node) orelse continue;
            break :members container.ast.members;
        };

        for (members) |member| {
            const name = name_of(tree, member) orelse continue;
            const member_key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ item.key, name });

            if (try member_doc(arena, tree, member)) |words| {
                try add(arena, out, member_key, words);
            }

            const inner = container_of(tree, member) orelse continue;

            if (item.depth + 1 < depth_max) {
                try pending.append(arena, .{
                    .node = inner,
                    .key = member_key,
                    .depth = item.depth + 1,
                });
            }
        }
    }
}

/// Every `publr.operation.define(In, Out, .{ .name = "answer", ... })` in the file: its words
/// filed under `operation:answer`, from the `///` above it or else the file's `//!`, so the
/// operation finds them wherever it is declared.
fn collect_definitions(
    arena: std.mem.Allocator,
    tree: *const Ast,
    file_words: ?[]const u8,
    out: *std.ArrayList(Entry),
) !void {
    std.debug.assert(tree.errors.len == 0);
    std.debug.assert(tree.nodes.len > 0);

    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        const declaration = tree.fullVarDecl(node) orelse continue;
        const init = declaration.ast.init_node.unwrap() orelse continue;
        const verb = defined_name(tree, init, "operation.define") orelse continue;
        const words = try member_doc(arena, tree, node) orelse file_words orelse continue;
        const key = try std.fmt.allocPrint(arena, "operation:{s}", .{verb});

        try add(arena, out, key, words);
    }
}

/// A hook's or modifier's reason, its `run` function's `///`, filed under `hook:<position>` in
/// `publr.plugin.define`'s `.hooks`, written there or in the constant it names.
fn collect_hooks(
    arena: std.mem.Allocator,
    tree: *const Ast,
    key: []const u8,
    out: *std.ArrayList(Entry),
) !void {
    std.debug.assert(tree.errors.len == 0);
    std.debug.assert(tree.nodes.len > 0);

    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        const hooks = option_of(tree, node, "plugin.define", "hooks") orelse continue;
        const list = declared_value(tree, hooks);
        var buffer: [2]Ast.Node.Index = undefined;
        const array = tree.fullArrayInit(&buffer, unwrapped(tree, list)) orelse return;

        for (array.ast.elements, 0..) |element, position| {
            const run = run_of(tree, element) orelse continue;
            const hook_key = try std.fmt.allocPrint(arena, "hook:{d}", .{position});

            if (try imported_member(arena, tree, key, run)) |target| {
                try out.append(arena, .{
                    .key = hook_key,
                    .text = "",
                    .alias = target,
                });
                continue;
            }

            if (tree.nodeTag(run) != .identifier) {
                continue;
            }

            const function = root_named(tree, tree.tokenSlice(tree.nodeMainToken(run)));
            const words = try member_doc(arena, tree, function orelse continue) orelse continue;

            try add(arena, out, hook_key, words);
        }

        return;
    }
}

/// `Shout.run`, where the file says `const Shout = @import("hooks/shout.zig")`: the key its
/// words are kept under (`hooks.shout.run`); null for anything else.
fn imported_member(
    arena: std.mem.Allocator,
    tree: *const Ast,
    key: []const u8,
    node: Ast.Node.Index,
) !?[]const u8 {
    std.debug.assert(key.len > 0);

    if (tree.nodeTag(node) != .field_access) {
        return null;
    }

    const written = node_source(tree, node);
    const dot = std.mem.indexOfScalar(u8, written, '.') orelse return null;
    const declared = root_named(tree, written[0..dot]) orelse return null;
    const declaration = tree.fullVarDecl(declared) orelse return null;
    const init = declaration.ast.init_node.unwrap() orelse return null;
    const source = node_source(tree, init);
    const prefix = "@import(\"";

    if (!std.mem.startsWith(u8, source, prefix) or !std.mem.endsWith(u8, source, "\")")) {
        return null;
    }

    const path = source[prefix.len .. source.len - 2];

    return doc_imports.member_key(arena, key, path, written[dot + 1 ..]);
}

/// The function a hook names, its last argument: `publr.before(Target, run)`, `after`, `on`,
/// `publr.modify("name", run)`.
fn run_of(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    std.debug.assert(@intFromEnum(node) < tree.nodes.len);

    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, node) orelse return null;
    const function = node_source(tree, call.ast.fn_expr);
    const shapes = [_][]const u8{ "publr.before", "publr.after", "publr.on", "publr.modify" };

    if (call.ast.params.len != 2) {
        return null;
    }

    for (shapes) |shape| {
        if (std.mem.endsWith(u8, function, shape)) {
            return call.ast.params[1];
        }
    }

    return null;
}

/// The value given to `.<field>` in a call to a function whose path ends `callee`.
fn option_of(
    tree: *const Ast,
    node: Ast.Node.Index,
    comptime callee: []const u8,
    comptime field_name: []const u8,
) ?Ast.Node.Index {
    std.debug.assert(@intFromEnum(node) < tree.nodes.len);

    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, node) orelse return null;
    const function = node_source(tree, call.ast.fn_expr);

    if (!std.mem.endsWith(u8, function, callee) or call.ast.params.len == 0) {
        return null;
    }

    var init_buffer: [2]Ast.Node.Index = undefined;
    const options = call.ast.params[call.ast.params.len - 1];
    const init = tree.fullStructInit(&init_buffer, options) orelse return null;

    for (init.ast.fields) |field| {
        if (std.mem.eql(u8, tree.tokenSlice(tree.firstToken(field) - 2), field_name)) {
            return field;
        }
    }

    return null;
}

/// A name's value when it names a constant of the file; the node itself otherwise.
fn declared_value(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    std.debug.assert(@intFromEnum(node) < tree.nodes.len);

    if (tree.nodeTag(node) != .identifier) {
        return node;
    }

    const declared = root_named(tree, tree.tokenSlice(tree.nodeMainToken(node))) orelse {
        return node;
    };
    const declaration = tree.fullVarDecl(declared) orelse return node;

    return declaration.ast.init_node.unwrap() orelse node;
}

/// `&.{ ... }` as its `.{ ... }`.
fn unwrapped(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    std.debug.assert(@intFromEnum(node) < tree.nodes.len);

    if (tree.nodeTag(node) == .address_of) {
        return tree.nodeData(node).node;
    }

    return node;
}

/// The file's top-level declaration called `name`; null when there is none.
fn root_named(tree: *const Ast, name: []const u8) ?Ast.Node.Index {
    std.debug.assert(name.len > 0);

    for (tree.rootDecls()) |member| {
        const found = name_of(tree, member) orelse continue;

        if (std.mem.eql(u8, found, name)) {
            return member;
        }
    }

    return null;
}

fn node_source(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    std.debug.assert(@intFromEnum(node) < tree.nodes.len);

    const start = tree.tokenStart(tree.firstToken(node));
    const last = tree.lastToken(node);

    return tree.source[start .. tree.tokenStart(last) + tree.tokenSlice(last).len];
}

/// The `.name` a `<callee>(..., .{ .name = "x", ... })` call gives; null for any other node.
fn defined_name(tree: *const Ast, node: Ast.Node.Index, comptime callee: []const u8) ?[]const u8 {
    std.debug.assert(callee.len > 0);

    const field = option_of(tree, node, callee, "name") orelse return null;

    if (tree.nodeTag(field) != .string_literal) {
        return null;
    }

    const literal = tree.tokenSlice(tree.nodeMainToken(field));

    return literal[1 .. literal.len - 1];
}

fn add(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Entry),
    key: []const u8,
    text: []const u8,
) !void {
    std.debug.assert(key.len > 0);
    std.debug.assert(text.len > 0);

    if (out.items.len == entries_max) {
        return error.TooManyDocComments;
    }

    if (key.len > key_len_max) {
        return error.DocKeyTooLong;
    }

    try out.append(arena, .{
        .key = key,
        .text = text,
    });
}

/// A declaration's or field's name; null for anything else (tests, `comptime` blocks).
fn name_of(tree: *const Ast, member: Ast.Node.Index) ?[]const u8 {
    std.debug.assert(tree.nodes.len > 0);
    std.debug.assert(@intFromEnum(member) < tree.nodes.len);

    if (tree.fullVarDecl(member)) |declaration| {
        return tree.tokenSlice(declaration.ast.mut_token + 1);
    }

    if (tree.fullContainerField(member)) |field| {
        return tree.tokenSlice(field.ast.main_token);
    }

    var buffer: [1]Ast.Node.Index = undefined;

    if (tree.fullFnProto(&buffer, member)) |proto| {
        const token = proto.name_token orelse return null;
        return tree.tokenSlice(token);
    }

    if (tree.nodeTag(member) == .fn_decl) {
        const proto_node = tree.nodeData(member).node_and_node[0];
        const proto = tree.fullFnProto(&buffer, proto_node) orelse return null;
        const token = proto.name_token orelse return null;

        return tree.tokenSlice(token);
    }

    return null;
}

/// The struct, enum or union a member declares inline: `const In = struct { ... }`, or a
/// field typed `struct { ... }`. Null for anything else.
fn container_of(tree: *const Ast, member: Ast.Node.Index) ?Ast.Node.Index {
    std.debug.assert(tree.nodes.len > 0);
    std.debug.assert(@intFromEnum(member) < tree.nodes.len);

    var buffer: [2]Ast.Node.Index = undefined;

    if (tree.fullVarDecl(member)) |declaration| {
        const init = declaration.ast.init_node.unwrap() orelse return null;
        _ = tree.fullContainerDecl(&buffer, init) orelse return null;

        return init;
    }

    if (tree.fullContainerField(member)) |field| {
        const kind = field.ast.type_expr.unwrap() orelse return null;
        _ = tree.fullContainerDecl(&buffer, kind) orelse return null;

        return kind;
    }

    return null;
}

/// The `///` lines right above a member, joined; null when there are none.
fn member_doc(arena: std.mem.Allocator, tree: *const Ast, member: Ast.Node.Index) !?[]const u8 {
    std.debug.assert(tree.nodes.len > 0);
    std.debug.assert(@intFromEnum(member) < tree.nodes.len);

    const first = tree.firstToken(member);
    var start = first;

    while (start > 0 and tree.tokenTag(start - 1) == .doc_comment) {
        start -= 1;
    }

    if (start == first) {
        return null;
    }

    return try joined(arena, tree, start, first, "///");
}

/// The `//!` lines at the top of the file, joined; null when there are none.
fn container_doc(arena: std.mem.Allocator, tree: *const Ast) !?[]const u8 {
    std.debug.assert(tree.tokens.len > 0);
    std.debug.assert(tree.errors.len == 0);

    var end: Ast.TokenIndex = 0;

    while (end < tree.tokens.len and tree.tokenTag(end) == .container_doc_comment) {
        end += 1;
    }

    if (end == 0) {
        return null;
    }

    return try joined(arena, tree, 0, end, "//!");
}

fn joined(
    arena: std.mem.Allocator,
    tree: *const Ast,
    start: Ast.TokenIndex,
    end: Ast.TokenIndex,
    marker: []const u8,
) ![]const u8 {
    std.debug.assert(start < end);
    std.debug.assert(marker.len == 3);

    var text: std.ArrayList(u8) = .empty;

    for (start..end) |index| {
        const raw = tree.tokenSlice(@intCast(index));
        const after = raw[marker.len..];
        const line = if (std.mem.startsWith(u8, after, " ")) after[1..] else after;

        if (text.items.len > 0) {
            try text.append(arena, '\n');
        }

        try text.appendSlice(arena, std.mem.trimEnd(u8, line, " \t\r"));
    }

    return text.items;
}

/// The entries as a Zig source file the build adds beside the plugin: each a declaration
/// named by its key, found by name, never by looking through the rest, and split here into
/// its first line and the rest so compiling the plugin reads no text a byte at a time. A key
/// read twice keeps its first words.
pub fn generated(arena: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    std.debug.assert(entries.len <= entries_max);

    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(arena, "const words = struct {\n");

    for (entries, 0..) |entry, index| {
        if (seen_before(entries[0..index], entry.key)) {
            continue;
        }

        const text = if (entry.alias.len > 0)
            text_of(entries, entry.alias) orelse continue
        else
            entry.text;
        const parts = split(text);

        try out.print(arena, "    pub const @\"{f}\" = .{{ \"{f}\", \"{f}\", \"{f}\" }};\n", .{
            std.zig.fmtString(entry.key),
            std.zig.fmtString(text),
            std.zig.fmtString(parts.first),
            std.zig.fmtString(parts.rest),
        });
    }

    try out.appendSlice(arena, "};\n\n" ++
        "pub fn get(comptime key: []const u8) ?[]const u8 {\n" ++
        "    return if (@hasDecl(words, key)) @field(words, key)[0] else null;\n" ++
        "}\n\n" ++
        "pub fn first(comptime key: []const u8) ?[]const u8 {\n" ++
        "    return if (@hasDecl(words, key)) @field(words, key)[1] else null;\n" ++
        "}\n\n" ++
        "pub fn rest(comptime key: []const u8) ?[]const u8 {\n" ++
        "    return if (@hasDecl(words, key)) @field(words, key)[2] else null;\n" ++
        "}\n");

    return out.items;
}

/// The words kept under `key` itself, never through another alias.
fn text_of(entries: []const Entry, key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(entries.len <= entries_max);

    for (entries) |entry| {
        if (entry.alias.len == 0 and std.mem.eql(u8, entry.key, key)) {
            return entry.text;
        }
    }

    return null;
}

pub const Parts = struct {
    /// The first line, without the spaces around it.
    first: []const u8,
    /// Everything after it, without the blank lines and spaces around it.
    rest: []const u8,
};

/// Words as the admin and the help show them: a name or summary, then the text under it.
pub fn split(text: []const u8) Parts {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const parts: Parts = .{
        .first = std.mem.trim(u8, text[0..end], " "),
        .rest = std.mem.trim(u8, text[end..], " \n"),
    };

    std.debug.assert(parts.first.len <= text.len);
    std.debug.assert(parts.rest.len <= text.len);

    return parts;
}

fn seen_before(earlier: []const Entry, key: []const u8) bool {
    std.debug.assert(earlier.len <= entries_max);

    for (earlier) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            return true;
        }
    }

    return false;
}

test "a file's own words and every declaration's" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\//! Asks visitors whether a page helped.
        \\//!
        \\//! The answers show under Page answers.
        \\const publr = @import("publr");
        \\
        \\pub const In = struct {
        \\    /// The page's address
        \\    page: []const u8,
        \\    /// What the visitor
        \\    ///   answered
        \\    data: struct {
        \\        /// Yes or no
        \\        yes: bool,
        \\    },
        \\    undocumented: u8,
        \\};
        \\
        \\/// Counts the answer.
        \\pub fn run() void {}
        \\
        \\test "not a declaration" {}
        \\
    ;
    var entries: std.ArrayList(Entry) = .empty;

    try read(arena, "operations.answer", text, &entries);

    const expected = [_]Entry{
        .{
            .key = "operations.answer",
            .text = "Asks visitors whether a page helped.\n\nThe answers show under Page answers.",
        },
        .{
            .key = "operations.answer.run",
            .text = "Counts the answer.",
        },
        .{
            .key = "operations.answer.In.page",
            .text = "The page's address",
        },
        .{
            .key = "operations.answer.In.data",
            .text = "What the visitor\n  answered",
        },
        .{
            .key = "operations.answer.In.data.yes",
            .text = "Yes or no",
        },
    };

    try std.testing.expectEqual(expected.len, entries.items.len);

    for (expected) |want| {
        const found = for (entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, want.key)) {
                break entry;
            }
        } else return error.TestExpectedEqual;

        try std.testing.expectEqualStrings(want.text, found.text);
    }
}

test "an operation's words filed under its name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\//! Records a visitor's answer.
        \\const publr = @import("publr");
        \\
        \\pub const operation = publr.operation.define(In, Out, .{
        \\    .name = "answer",
        \\    .run = run,
        \\});
        \\
        \\/// Counts the answers.
        \\pub const counts = publr.operation.define(CountsIn, CountsOut, .{
        \\    .name = "counts",
        \\});
        \\
    ;
    var entries: std.ArrayList(Entry) = .empty;

    try read(arena, "operations.answer", text, &entries);

    var answer: ?[]const u8 = null;
    var counts: ?[]const u8 = null;

    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, "operation:answer")) {
            answer = entry.text;
        }

        if (std.mem.eql(u8, entry.key, "operation:counts")) {
            counts = entry.text;
        }
    }

    try std.testing.expectEqualStrings("Records a visitor's answer.", answer.?);
    try std.testing.expectEqualStrings("Counts the answers.", counts.?);
}

test "a hook's reason is its run function's words, by its place in .hooks" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\const publr = @import("publr");
        \\
        \\/// Emits an event for every greeting.
        \\fn announce(ctx: *publr.Ctx, in: *In, out: *const Out) publr.Error!void {}
        \\
        \\fn quiet(ctx: *publr.Ctx, in: *In) publr.Error!void {}
        \\
        \\/// Thanks whoever greeted.
        \\fn thank(ctx: *publr.Ctx, payload: Payload) publr.Error!void {}
        \\
        \\const hooks = .{
        \\    publr.after(Record, announce),
        \\    publr.before(Record, quiet),
        \\    publr.on(Recorded, thank),
        \\};
        \\
        \\pub const plugin = publr.plugin.define(manifest, .{
        \\    .hooks = hooks,
        \\});
        \\
    ;
    var entries: std.ArrayList(Entry) = .empty;

    try read(arena, "main", text, &entries);

    var found: [3]?[]const u8 = @splat(null);

    for (entries.items) |entry| {
        if (std.mem.startsWith(u8, entry.key, "hook:")) {
            found[try std.fmt.parseInt(u32, entry.key[5..], 10)] = entry.text;
        }
    }

    try std.testing.expectEqualStrings("Emits an event for every greeting.", found[0].?);
    try std.testing.expect(found[1] == null);
    try std.testing.expectEqualStrings("Thanks whoever greeted.", found[2].?);
}

test "a file without words, one that does not parse, and the generated source" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entries: std.ArrayList(Entry) = .empty;

    try read(arena, "main", "const answer = 1;\n", &entries);
    try read(arena, "main", "pub const = ;\n", &entries);
    try std.testing.expectEqual(0, entries.items.len);
    const key = try file_key(arena, "operations/answer.zig");

    try std.testing.expectEqualStrings("operations.answer", key);

    const written = try generated(arena, &.{.{
        .key = "main",
        .text = "Say \"hi\"\nthere",
    }});

    try std.testing.expect(std.mem.indexOf(u8, written, "pub const @\"main\" = " ++
        ".{ \"Say \\\"hi\\\"\\nthere\", \"Say \\\"hi\\\"\", \"there\" };") != null);
    try std.testing.expectEqualStrings("Name", split("  Name \n\n Text\n").first);
    try std.testing.expectEqualStrings("Text", split("  Name \n\n Text\n").rest);
    try std.testing.expectEqualStrings("", split("Name").rest);
    try std.testing.expect(std.mem.indexOf(u8, written, "pub fn get(") != null);
}

test "a hook listed in main whose function is in another file takes that function's words" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    const main =
        \\const Shout = @import("hooks/shout.zig");
        \\pub const plugin = publr.plugin.define(manifest, .{
        \\    .hooks = .{ publr.before(Note, Shout.run) },
        \\});
        \\
    ;
    const shout =
        \\/// Keeps every note in capitals
        \\pub fn run() void {}
        \\
    ;

    try read(arena, "main", main, &entries);
    try read(arena, try file_key(arena, "hooks/shout.zig"), shout, &entries);

    const written = try generated(arena, entries.items);

    try std.testing.expect(std.mem.indexOf(u8, written, "pub const @\"hook:0\" = " ++
        ".{ \"Keeps every note in capitals\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "hooks.shout.run") != null);
}
