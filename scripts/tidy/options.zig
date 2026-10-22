//! Optional parameters have one shape: required ones are direct, optional ones go in one
//! `options: Options` struct, always the last parameter, where every field has a default.
//! Tidy checks what it can see in one file: the parameter's name, its place, and that an
//! `Options` struct holds no required field. A `?T` that callers fill with `null`, or a
//! `foo` beside a `foo_with`, needs the callers to judge, so `STYLE.md` covers those.
//! `export` and `extern` functions follow the C ABI and are left alone, and so is an
//! `anytype` options parameter, which comptime declarations take on purpose.
const std = @import("std");
const Ast = std.zig.Ast;

pub const Problem = enum {
    short_name,
    not_last,
    required_field,
};

pub const messages: std.EnumArray(Problem, []const u8) = .init(.{
    .short_name = "optional parameters are `options: Options`, never `opts`",
    .not_last = "`options` is the last parameter",
    .required_field = "every field of an `Options` struct has a default; " ++
        "a required one is a direct parameter",
});

pub const Found = struct {
    line: u32,
    problem: Problem,
};

pub const found_max: u32 = 100_000;

/// Every place in `source` that breaks the options shape, in source order.
pub fn find(gpa: std.mem.Allocator, source: [:0]const u8) ![]Found {
    std.debug.assert(source.len < std.math.maxInt(u32));

    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    var found: std.ArrayList(Found) = .empty;
    errdefer found.deinit(gpa);

    if (tree.errors.len > 0) {
        return found.toOwnedSlice(gpa);
    }

    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        var buffer: [1]Ast.Node.Index = undefined;

        // A declaration's prototype is a node of its own, so the declaration is skipped.
        if (tree.nodeTag(node) == .fn_decl) {
            continue;
        }
        if (tree.fullFnProto(&buffer, node)) |proto| {
            try check_parameters(gpa, &tree, proto, &found);
        } else if (tree.fullVarDecl(node)) |declaration| {
            try check_declaration(gpa, &tree, declaration, &found);
        }
    }

    std.mem.sort(Found, found.items, {}, before);

    std.debug.assert(found.items.len <= found_max);

    return found.toOwnedSlice(gpa);
}

fn before(_: void, left: Found, right: Found) bool {
    return left.line < right.line;
}

fn check_parameters(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    proto: Ast.full.FnProto,
    found: *std.ArrayList(Found),
) !void {
    std.debug.assert(tree.nodes.len > 0);

    if (proto.extern_export_inline_token) |token| {
        if (tree.tokenTag(token) != .keyword_inline) {
            return;
        }
    }

    var count: u32 = 0;
    var options_at: ?u32 = null;
    var options_token: Ast.TokenIndex = 0;
    var iterator = proto.iterate(tree);

    while (iterator.next()) |parameter| : (count += 1) {
        const name_token = parameter.name_token orelse continue;
        const name = tree.tokenSlice(name_token);

        if (std.mem.eql(u8, name, "opts")) {
            try add(gpa, tree, found, name_token, .short_name);
        }
        if (std.mem.eql(u8, name, "options") and parameter.anytype_ellipsis3 == null) {
            options_at = count;
            options_token = name_token;
        }
    }

    std.debug.assert(options_at == null or options_at.? < count);

    if (options_at) |at| {
        if (at + 1 != count) {
            try add(gpa, tree, found, options_token, .not_last);
        }
    }
}

/// `const FooOptions = struct { ... }`: each field has a default.
fn check_declaration(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    declaration: Ast.full.VarDecl,
    found: *std.ArrayList(Found),
) !void {
    std.debug.assert(tree.nodes.len > 0);

    const name = tree.tokenSlice(declaration.ast.mut_token + 1);
    const init = declaration.ast.init_node.unwrap() orelse return;

    if (!std.mem.endsWith(u8, name, "Options")) {
        return;
    }

    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, init) orelse return;

    if (tree.tokenTag(container.ast.main_token) != .keyword_struct) {
        return;
    }

    std.debug.assert(name.len >= "Options".len);

    for (container.ast.members) |member| {
        const field = tree.fullContainerField(member) orelse continue;

        if (field.ast.tuple_like or field.comptime_token != null) {
            continue;
        }
        if (field.ast.value_expr == .none) {
            try add(gpa, tree, found, field.ast.main_token, .required_field);
        }
    }
}

fn add(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    found: *std.ArrayList(Found),
    token: Ast.TokenIndex,
    problem: Problem,
) !void {
    std.debug.assert(token < tree.tokens.len);

    if (found.items.len == found_max) {
        return error.TooManyFound;
    }

    const start = tree.tokenStart(token);
    const line: u32 = @intCast(std.mem.count(u8, tree.source[0..start], "\n") + 1);

    std.debug.assert(line > 0);

    try found.append(gpa, .{
        .line = line,
        .problem = problem,
    });
}

fn expect_found(source: [:0]const u8, expected: []const Found) !void {
    const found = try find(std.testing.allocator, source);
    defer std.testing.allocator.free(found);

    try std.testing.expectEqualSlices(Found, expected, found);
}

test "options go last, are named options, and default every field" {
    try expect_found(
        \\const Options = struct {
        \\    retries: u8 = 3,
        \\};
        \\fn fetch(url: []const u8, options: Options) void {}
        \\fn define(options: anytype, name: []const u8) void {}
        \\fn parse(options: std.json.ParseOptions) void {}
    , &.{});

    try expect_found(
        \\const FetchOptions = struct {
        \\    url: []const u8,
        \\    retries: u8 = 3,
        \\};
        \\fn fetch(options: FetchOptions, url: []const u8) void {}
        \\fn draw(opts: FetchOptions) void {}
    , &.{
        .{
            .line = 2,
            .problem = .required_field,
        },
        .{
            .line = 5,
            .problem = .not_last,
        },
        .{
            .line = 6,
            .problem = .short_name,
        },
    });
}

test "C ABI functions and data structs keep their shape" {
    try expect_found(
        \\export fn compile(options: u32, len: u32) void {}
        \\extern fn open(opts: c_int, vfs: ?[*:0]const u8) c_int;
        \\const Config = struct {
        \\    base: []const u8,
        \\};
        \\inline fn fold(options: Options, count: u32) void {}
    , &.{
        .{
            .line = 6,
            .problem = .not_last,
        },
    });
}
