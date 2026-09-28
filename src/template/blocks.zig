//! `{...}` in child position: a map loop, a conditional, or a value written by type.

const std = @import("std");
const ast = @import("ast.zig");
const compile = @import("compile.zig");
const expression = @import("expression.zig");
const markup = @import("markup.zig");

const Compiler = compile.Compiler;
const Error = compile.Error;
const Node = ast.Node;

pub fn child(compiler: *Compiler, inner: []const u8) Error!void {
    std.debug.assert(compiler.template.compiling);

    const trimmed = std.mem.trim(u8, inner, " \t\r\n");

    if (trimmed.len == 0) {
        return;
    }

    // A conditional first: only a top-level `?` makes one, and its branches may loop.
    if (try conditional(compiler, trimmed)) {
        return;
    }

    if (try map_loop(compiler, trimmed)) {
        return;
    }

    try expression.write_value(compiler, try expression.expression(compiler, trimmed));
}

/// `items.map((item) => ( ... ))`
fn map_loop(compiler: *Compiler, text: []const u8) Error!bool {
    std.debug.assert(text.len > 0);

    const map_at = std.mem.indexOf(u8, text, ".map((") orelse return false;
    const collection = text[0..map_at];

    if (!expression.is_identifier(collection)) {
        return compiler.fail(
            "map loops need a plain collection identifier: {s}",
            .{compiler.excerpt(text)},
        );
    }

    const after = text[map_at + ".map((".len ..];
    const param_end = std.mem.indexOfScalar(u8, after, ')') orelse {
        return compiler.fail("malformed map callback: {s}", .{compiler.excerpt(text)});
    };
    const param = std.mem.trim(u8, after[0..param_end], " \t");

    if (!expression.is_identifier(param)) {
        return compiler.fail(
            "map callbacks take one item parameter: {s}",
            .{compiler.excerpt(text)},
        );
    }

    const body_text = try loop_body(compiler, text, after[param_end + 1 ..]);
    const subject = compiler.find_local(collection) orelse {
        return compiler.fail("`{s}` is not declared", .{collection});
    };

    if (subject.type != .collection) {
        return compiler.fail(
            "`.map` on `{s}`, which is a {s}, not a collection",
            .{ collection, @tagName(subject.type) },
        );
    }

    const locals_before = compiler.locals.items.len;

    try compiler.add_local(param, .entry);
    const body = try markup.sub_list(compiler, body_text);
    _ = compiler.locals.pop();

    std.debug.assert(compiler.locals.items.len == locals_before);

    try compiler.push(.{ .loop = .{ .collection = collection, .param = param, .body = body } });

    return true;
}

/// The markup between `=> (` and the closing `))`.
fn loop_body(compiler: *Compiler, text: []const u8, after_param: []const u8) Error![]const u8 {
    std.debug.assert(after_param.len <= text.len);

    var rest = std.mem.trim(u8, after_param, " \t\r\n");

    if (!std.mem.startsWith(u8, rest, "=>")) {
        return compiler.fail("malformed map callback: {s}", .{compiler.excerpt(text)});
    }

    rest = std.mem.trim(u8, rest[2..], " \t\r\n");

    if (!std.mem.startsWith(u8, rest, "(") or !std.mem.endsWith(u8, rest, "))")) {
        return compiler.fail(
            "map callbacks need a parenthesized JSX body: {s}",
            .{compiler.excerpt(text)},
        );
    }

    std.debug.assert(rest.len >= 3);

    return rest[1 .. rest.len - 2];
}

/// `test ? ( ... ) : ( ... )` with markup (or `null`) in the branches.
fn conditional(compiler: *Compiler, text: []const u8) Error!bool {
    std.debug.assert(text.len > 0);

    const question = expression.top_level(text, '?') orelse return false;
    const colon = expression.top_level(text[question + 1 ..], ':') orelse {
        return compiler.fail("conditional without `:`: {s}", .{compiler.excerpt(text)});
    };
    const test_text = std.mem.trim(u8, text[0..question], " \t\r\n");
    const consequent = std.mem.trim(u8, text[question + 1 .. question + 1 + colon], " \t\r\n");
    const alternate = std.mem.trim(u8, text[question + 1 + colon + 1 ..], " \t\r\n");

    const condition = try expression.expression(compiler, test_text);
    try expression.check_truthy(compiler, condition);
    const then_nodes = try branch(compiler, consequent);
    const else_nodes = try branch(compiler, alternate);

    try compiler.push(.{ .cond = .{
        .condition = condition,
        .consequent = then_nodes,
        .alternate = else_nodes,
    } });

    return true;
}

fn branch(compiler: *Compiler, text: []const u8) Error![]const Node {
    std.debug.assert(compiler.template.compiling);

    if (std.mem.eql(u8, text, "null")) {
        return &.{};
    }

    var inner = text;

    if (inner.len >= 2 and inner[0] == '(' and inner[inner.len - 1] == ')') {
        inner = std.mem.trim(u8, inner[1 .. inner.len - 1], " \t\r\n");
    }

    if (inner.len > 0 and inner[0] == '<') {
        return markup.sub_list(compiler, inner);
    }

    var list: std.ArrayList(Node) = .empty;
    const outer = compiler.out;

    try compiler.flush();
    compiler.out = &list;
    try expression.write_value(compiler, try expression.expression(compiler, inner));
    try compiler.flush();
    compiler.out = outer;

    std.debug.assert(compiler.out == outer);

    return list.items;
}
