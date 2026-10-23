//! `publr plugin check`: what the rules forbid and the compiler cannot see, read from a
//! plugin's source by name and type together. Money, times and references kept as plain
//! numbers or text, JSON kept in text, an untrusted write taking facts the server owns, an
//! import reaching outside the plugin's folder, a `ctx.fail` name its `Fails:` does not list
//! and a `Fails:` line no `ctx.fail` uses. A `Why:` line in the field's own `///` passes
//! a name check and shows to whoever reviews the plugin. One implementation for
//! `plugin build`, Publr's `zig build`, and the install gate.
const std = @import("std");
const Ast = std.zig.Ast;

pub const Problem = struct {
    line: u32,
    message: []const u8,
};

pub const problems_max: u32 = 256;

const money_names = [_][]const u8{ "price", "total", "amount", "subtotal", "cost", "fee" };
const fact_names = [_][]const u8{ "price", "total", "discount", "rules", "amount", "subtotal" };
const json_names = [_][]const u8{ "data", "payload", "json", "blob" };
const integer_types = [_][]const u8{
    "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "isize", "usize",
};
const money_suffixes = [_][]const u8{ "_cents", "_amount", "_price" };
const money_message = "`{s}` keeps money as a number: make it a money field " ++
    "(`.kind = \"money\"`), or say `Why:`";
const time_message = "`{s}` keeps a time as a number: make it `publr.Time`, or say `Why:`";
const reference_message = "`{s}` keeps a reference as text: make it a `Ref`, or say `Why:`";
const json_message = "`{s}` keeps JSON in text: make it a struct field, or say `Why:`";
const fact_message = "`{s}`: an untrusted write takes facts the server owns; send a " ++
    "reference and look it up, or say `Why:`";
const import_message = "`{s}` reaches outside the plugin's folder: name the gap instead of " ++
    "sharing code";

/// Every problem in one file, appended to `out`.
pub fn check(
    arena: std.mem.Allocator,
    path: []const u8,
    text: [:0]const u8,
    out: *std.ArrayList(Problem),
) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(text.len < std.math.maxInt(u32));

    var tree = try Ast.parse(arena, text, .zig);

    // The rest reads the tree: a file that does not parse says so, and nothing else.
    if (tree.errors.len > 0) {
        const first = tree.errors[0];
        var message: std.Io.Writer.Allocating = .init(arena);

        try message.writer.writeAll("does not parse: ");
        try tree.renderError(first, &message.writer);
        try out.append(arena, .{
            .line = line_of(&tree, first.token),
            .message = message.written(),
        });

        return;
    }

    const untrusted_inputs = try untrusted_write_inputs(arena, &tree);

    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);

        if (tree.fullContainerField(node)) |field| {
            try check_field(arena, &tree, node, field, untrusted_inputs, out);
        }

        const tag = tree.nodeTag(node);

        if (tag == .builtin_call_two or tag == .builtin_call_two_comma) {
            try check_import(arena, &tree, node, path, out);
        }
    }
}

fn check_field(
    arena: std.mem.Allocator,
    tree: *const Ast,
    node: Ast.Node.Index,
    field: Ast.full.ContainerField,
    untrusted_inputs: []const []const u8,
    out: *std.ArrayList(Problem),
) !void {
    std.debug.assert(tree.errors.len == 0);
    std.debug.assert(@intFromEnum(node) < tree.nodes.len);

    const name = tree.tokenSlice(field.ast.main_token);
    const type_node = field.ast.type_expr.unwrap() orelse return;
    const type_text = node_text(tree, type_node);

    if (has_reason(tree, node)) {
        return;
    }

    const line = line_of(tree, field.ast.main_token);
    const integer = listed(&integer_types, std.mem.trimStart(u8, type_text, "?"));
    const text_field = std.mem.eql(u8, std.mem.trimStart(u8, type_text, "?"), "[]const u8");

    const money = listed(&money_names, name) or ends_with_any(name, &money_suffixes);
    const time = std.mem.eql(u8, name, "at") or std.mem.endsWith(u8, name, "_at") or
        std.mem.startsWith(u8, name, "expires") or std.mem.eql(u8, name, "deadline");
    const json = std.mem.endsWith(u8, name, "_json") or listed(&json_names, name);

    if (integer and money) {
        try add(arena, out, line, money_message, name);
    }

    if (integer and time) {
        try add(arena, out, line, time_message, name);
    }

    if (text_field and std.mem.endsWith(u8, name, "_id")) {
        try add(arena, out, line, reference_message, name);
    }

    if (text_field and json) {
        try add(arena, out, line, json_message, name);
    }

    if (listed(&fact_names, name) or std.mem.indexOf(u8, type_text, "Money") != null) {
        const container = enclosing_container_name(tree, node) orelse return;

        if (listed(untrusted_inputs, container)) {
            try add(arena, out, line, fact_message, name);
        }
    }
}

fn check_import(
    arena: std.mem.Allocator,
    tree: *const Ast,
    node: Ast.Node.Index,
    path: []const u8,
    out: *std.ArrayList(Problem),
) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(@intFromEnum(node) < tree.nodes.len);

    const builtin = tree.tokenSlice(tree.nodeMainToken(node));

    if (!std.mem.eql(u8, builtin, "@import")) {
        return;
    }

    const text = node_text(tree, node);
    const open = std.mem.indexOfScalar(u8, text, '"') orelse return;
    const close = std.mem.lastIndexOfScalar(u8, text, '"') orelse return;

    if (close <= open + 1) {
        return;
    }

    const target = text[open + 1 .. close];

    if (!std.mem.endsWith(u8, target, ".zig")) {
        return;
    }

    const depth = std.mem.count(u8, path, "/");
    const ups = std.mem.count(u8, target, "../");

    if (ups > depth) {
        try add(arena, out, line_of(tree, tree.nodeMainToken(node)), import_message, target);
    }
}

/// The names of the structs given as `In` to an operation that writes and takes untrusted
/// callers: `publr.operation.define(SignIn, ..., .{ .kind = .write, .untrusted_callers = true })`.
fn untrusted_write_inputs(arena: std.mem.Allocator, tree: *const Ast) ![]const []const u8 {
    std.debug.assert(tree.errors.len == 0);

    var names: std.ArrayList([]const u8) = .empty;

    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        const function = node_text(tree, call.ast.fn_expr);

        if (!std.mem.endsWith(u8, function, "operation.define") or call.ast.params.len < 3) {
            continue;
        }

        const options = node_text(tree, call.ast.params[call.ast.params.len - 1]);
        const untrusted = std.mem.indexOf(u8, options, ".untrusted_callers = true") != null;
        const writes = std.mem.indexOf(u8, options, ".kind = .write") != null;

        if (untrusted and writes) {
            const input = node_text(tree, call.ast.params[0]);
            const last_dot = std.mem.lastIndexOfScalar(u8, input, '.');

            try names.append(arena, if (last_dot) |at| input[at + 1 ..] else input);
        }
    }

    return names.items;
}

/// The name of the struct a field sits in, when it is declared as `const Name = struct`.
fn enclosing_container_name(tree: *const Ast, field: Ast.Node.Index) ?[]const u8 {
    std.debug.assert(@intFromEnum(field) < tree.nodes.len);

    const field_start = tree.tokenStart(tree.firstToken(field));
    var best: ?[]const u8 = null;
    var best_start: u32 = 0;

    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        const declaration = tree.fullVarDecl(node) orelse continue;
        const init = declaration.ast.init_node.unwrap() orelse continue;
        var buffer: [2]Ast.Node.Index = undefined;

        _ = tree.fullContainerDecl(&buffer, init) orelse continue;

        const start = tree.tokenStart(tree.firstToken(init));
        const end_token = tree.lastToken(init);
        const end = tree.tokenStart(end_token);

        if (start <= field_start and field_start <= end and start >= best_start) {
            best = tree.tokenSlice(declaration.ast.mut_token + 1);
            best_start = start;
        }
    }

    return best;
}

/// Whether the field's `///` carries a `Why:` line.
fn has_reason(tree: *const Ast, node: Ast.Node.Index) bool {
    std.debug.assert(@intFromEnum(node) < tree.nodes.len);

    var token = tree.firstToken(node);

    while (token > 0 and tree.tokenTag(token - 1) == .doc_comment) {
        token -= 1;

        const line = std.mem.trim(u8, tree.tokenSlice(token)[3..], " ");

        if (std.mem.startsWith(u8, line, "Why:")) {
            return true;
        }
    }

    return false;
}

/// The refusals of a whole plugin, gathered file by file (`read`), then held against each
/// other (`problems`): a `ctx.fail(.Name, …)` is listed in its own file's `Fails:`, or in some
/// `Fails:` of the plugin when its file has none (a helper failing for its caller); a
/// `Fails:` line is used by some `ctx.fail` of the plugin, or named by an
/// `sdk.operation.Failure` value a built-in plugin hands core's own `ctx.fail`.
pub const Failures = struct {
    listed: std.ArrayList(Mention) = .empty,
    used: std.ArrayList(Mention) = .empty,
    /// Names of `sdk.operation.Failure` values: used, not checked against a list.
    defined: std.ArrayList(Mention) = .empty,
    /// A file did not parse (`check` reports it): no `Fails:` line is called unused.
    unparsed: bool = false,

    pub const Mention = struct {
        path: []const u8,
        line: u32,
        name: []const u8,
    };

    pub const Placed = struct {
        path: []const u8,
        problem: Problem,
    };

    pub fn read(
        failures: *Failures,
        arena: std.mem.Allocator,
        path: []const u8,
        text: [:0]const u8,
    ) !void {
        std.debug.assert(path.len > 0);
        std.debug.assert(text.len < std.math.maxInt(u32));

        try failures.read_listed(arena, path, text);
        try failures.read_used(arena, path, text);
    }

    /// Each `- Name (status): …` line under a `Fails:` in a doc comment.
    fn read_listed(
        failures: *Failures,
        arena: std.mem.Allocator,
        path: []const u8,
        text: []const u8,
    ) !void {
        std.debug.assert(path.len > 0);

        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: u32 = 0;
        var in_fails = false;

        while (lines.next()) |raw| {
            number += 1;

            const trimmed = std.mem.trim(u8, raw, " \t\r");
            const outer = std.mem.startsWith(u8, trimmed, "///") and
                !std.mem.startsWith(u8, trimmed, "////");
            const doc = std.mem.startsWith(u8, trimmed, "//!") or outer;

            if (!doc) {
                in_fails = false;
                continue;
            }

            const line = std.mem.trim(u8, trimmed[3..], " \t");

            if (std.mem.eql(u8, line, "Fails:")) {
                in_fails = true;
                continue;
            }

            if (std.mem.eql(u8, line, "Example:")) {
                in_fails = false;
                continue;
            }

            if (!in_fails or line.len == 0) {
                continue;
            }

            const body = std.mem.trim(u8, std.mem.trimStart(u8, line, "-"), " ");
            const end = std.mem.indexOfAny(u8, body, "(:") orelse continue;
            const name = std.mem.trim(u8, body[0..end], " ");

            if (name.len == 0) {
                continue;
            }

            try failures.listed.append(arena, .{
                .path = path,
                .line = number,
                .name = name,
            });
        }
    }

    /// Each `.fail(.Name` call, and each `Failure = .{ .name = "Name"` value.
    fn read_used(
        failures: *Failures,
        arena: std.mem.Allocator,
        path: []const u8,
        text: [:0]const u8,
    ) !void {
        std.debug.assert(path.len > 0);

        var tree = try Ast.parse(arena, text, .zig);

        // Its `ctx.fail` calls are unknown: the plugin's `Fails:` lines go unchecked.
        if (tree.errors.len > 0) {
            failures.unparsed = true;
            return;
        }

        const tags = tree.tokens.items(.tag);

        for (0..tags.len -| 4) |index| {
            const token: Ast.TokenIndex = @intCast(index);
            const call = tags[index] == .period and tags[index + 1] == .identifier and
                tags[index + 2] == .l_paren and tags[index + 3] == .period and
                tags[index + 4] == .identifier and
                std.mem.eql(u8, tree.tokenSlice(token + 1), "fail");

            if (call) {
                try failures.used.append(arena, .{
                    .path = path,
                    .line = line_of(&tree, token + 1),
                    .name = tree.tokenSlice(token + 4),
                });
            }

            const value = tags[index] == .identifier and
                std.mem.eql(u8, tree.tokenSlice(token), "Failure") and
                index + 7 < tags.len and tags[index + 1] == .equal and
                tags[index + 2] == .period and tags[index + 3] == .l_brace and
                tags[index + 4] == .period and tags[index + 5] == .identifier and
                std.mem.eql(u8, tree.tokenSlice(token + 5), "name") and
                tags[index + 6] == .equal and tags[index + 7] == .string_literal;

            if (value) {
                const quoted = tree.tokenSlice(token + 7);

                try failures.defined.append(arena, .{
                    .path = path,
                    .line = line_of(&tree, token + 7),
                    .name = quoted[1 .. quoted.len - 1],
                });
            }
        }
    }

    pub fn problems(failures: *const Failures, arena: std.mem.Allocator) ![]const Placed {
        std.debug.assert(failures.listed.items.len < 1 << 20);

        var out: std.ArrayList(Placed) = .empty;

        for (failures.used.items) |use| {
            const own_list = failures.lists_in(use.path);
            const found = if (own_list)
                failures.is_listed(use.name, use.path)
            else
                failures.is_listed(use.name, null);

            if (!found and out.items.len < problems_max) {
                const where = if (own_list) "this file's" else "any";

                try out.append(arena, .{
                    .path = use.path,
                    .problem = .{
                        .line = use.line,
                        .message = try std.fmt.allocPrint(arena, "`ctx.fail(.{s}, …)`: " ++
                            "{s} `Fails:` does not list `{s}`", .{ use.name, where, use.name }),
                    },
                });
            }
        }

        if (failures.unparsed) {
            return out.items;
        }

        for (failures.listed.items) |listed_one| {
            if (!failures.is_used(listed_one.name) and out.items.len < problems_max) {
                try out.append(arena, .{
                    .path = listed_one.path,
                    .problem = .{
                        .line = listed_one.line,
                        .message = try std.fmt.allocPrint(arena, "`Fails:` lists `{s}`, " ++
                            "but no `ctx.fail(.{s}, …)` uses it", .{
                            listed_one.name,
                            listed_one.name,
                        }),
                    },
                });
            }
        }

        return out.items;
    }

    fn lists_in(failures: *const Failures, path: []const u8) bool {
        std.debug.assert(path.len > 0);

        for (failures.listed.items) |listed_one| {
            if (std.mem.eql(u8, listed_one.path, path)) {
                return true;
            }
        }

        return false;
    }

    /// Whether `name` is listed in `path`'s `Fails:`, or in any when `path` is null.
    fn is_listed(failures: *const Failures, name: []const u8, path: ?[]const u8) bool {
        std.debug.assert(name.len > 0);

        for (failures.listed.items) |listed_one| {
            const here = if (path) |own| std.mem.eql(u8, listed_one.path, own) else true;

            if (here and std.mem.eql(u8, listed_one.name, name)) {
                return true;
            }
        }

        return false;
    }

    fn is_used(failures: *const Failures, name: []const u8) bool {
        std.debug.assert(name.len > 0);

        for (failures.used.items) |use| {
            if (std.mem.eql(u8, use.name, name)) {
                return true;
            }
        }

        for (failures.defined.items) |value| {
            if (std.mem.eql(u8, value.name, name)) {
                return true;
            }
        }

        return false;
    }
};

fn add(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Problem),
    line: u32,
    comptime format: []const u8,
    name: []const u8,
) !void {
    std.debug.assert(line > 0);
    std.debug.assert(name.len > 0);

    if (out.items.len == problems_max) {
        return;
    }

    try out.append(arena, .{
        .line = line,
        .message = try std.fmt.allocPrint(arena, format, .{name}),
    });
}

fn node_text(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    std.debug.assert(@intFromEnum(node) < tree.nodes.len);

    const start = tree.tokenStart(tree.firstToken(node));
    const last = tree.lastToken(node);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;

    return tree.source[start..end];
}

fn line_of(tree: *const Ast, token: Ast.TokenIndex) u32 {
    std.debug.assert(token < tree.tokens.len);

    const offset = tree.tokenStart(token);

    return @intCast(std.mem.count(u8, tree.source[0..offset], "\n") + 1);
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(names.len < 1024);

    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}

fn ends_with_any(name: []const u8, suffixes: []const []const u8) bool {
    std.debug.assert(suffixes.len > 0);

    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) {
            return true;
        }
    }

    return false;
}

test "plain money, times, references and JSON are caught; a reason passes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\const Order = struct {
        \\    total: u64,
        \\    created_at: i64,
        \\    product_id: []const u8,
        \\    extras_json: []const u8,
        \\    /// What the visitor chose to pay
        \\    ///
        \\    /// Why: pay what you want; the server checks the minimum
        \\    amount: u64,
        \\};
        \\
        \\const Buy = struct {
        \\    variant: Variants.Ref,
        \\    price: publr.Money,
        \\};
        \\
        \\pub const buy = publr.operation.define(Buy, Out, .{
        \\    .name = "buy",
        \\    .kind = .write,
        \\    .untrusted_callers = true,
        \\});
        \\
        \\const shared = @import("../../shared/util.zig");
        \\
    ;
    var problems: std.ArrayList(Problem) = .empty;

    try check(arena, "operations/order.zig", text, &problems);

    var lines: [8]u32 = undefined;

    for (problems.items, 0..) |problem, index| {
        lines[index] = problem.line;
    }

    try std.testing.expectEqual(6, problems.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4, 5, 14, 23 }, lines[0..problems.items.len]);
}

test "a ctx.fail name and its Fails: line agree both ways" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const operation =
        \\//! Reserve stock.
        \\//!
        \\//! Fails:
        \\//!
        \\//!     - NotEnoughStock (409): fewer left than asked
        \\//!     - OfferEnded (410): the offer is over
        \\//!     - Never: nothing raises this
        \\//!
        \\//! Example:
        \\//!
        \\//!     in:  {}
        \\//!     out: {}
        \\
        \\fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
        \\    if (in.count > 3) return ctx.fail(.NotEnoughStock, "Only {left} left", .{});
        \\    return ctx.fail(.Unlisted, "No.", .{});
        \\}
        \\
    ;
    const helper =
        \\pub const gone: sdk.operation.Failure = .{
        \\    .name = "Never",
        \\    .status = 410,
        \\    .message = "Gone",
        \\};
        \\
        \\pub fn end(ctx: *publr.Ctx) error{Failed} {
        \\    _ = ctx.fail(.Gone, "Gone.", .{});
        \\    return ctx.fail(.OfferEnded, "The offer is over.", .{});
        \\}
        \\
    ;
    var failures: Failures = .{};

    try failures.read(arena, "operations/reserve.zig", operation);
    try failures.read(arena, "helpers.zig", helper);

    const found = try failures.problems(arena);

    try std.testing.expectEqual(2, found.len);
    try std.testing.expectEqual(16, found[0].problem.line);
    try std.testing.expectEqualStrings("operations/reserve.zig", found[0].path);
    try std.testing.expectEqualStrings("helpers.zig", found[1].path);
    try std.testing.expectEqual(8, found[1].problem.line);

    var bare: Failures = .{};

    try bare.read(arena, "operations/reserve.zig", operation);

    const unused = try bare.problems(arena);

    try std.testing.expectEqual(3, unused.len);
    try std.testing.expectEqual(6, unused[1].problem.line);
    try std.testing.expectEqual(7, unused[2].problem.line);
}

test "a file that does not parse says so, and its Fails: lines are not called unused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const broken =
        \\//! Fails:
        \\//!     - NotEnoughStock (409): fewer left than asked
        \\
        \\fn run(ctx: *publr.Ctx) publr.Error!void {
        \\    return ctx.fail(.NotEnoughStock, "No.", .{})
        \\}
        \\
    ;
    var problems: std.ArrayList(Problem) = .empty;
    var failures: Failures = .{};

    try check(arena, "reserve.zig", broken, &problems);
    try failures.read(arena, "reserve.zig", broken);

    try std.testing.expectEqual(1, problems.items.len);
    try std.testing.expectEqual(5, problems.items[0].line);
    try std.testing.expect(std.mem.startsWith(u8, problems.items[0].message, "does not parse: "));
    try std.testing.expectEqual(0, (try failures.problems(arena)).len);
}
