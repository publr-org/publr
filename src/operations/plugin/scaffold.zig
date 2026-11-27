//! A plugin to start from: a working plugin with a page of its own in the admin, made of
//! the design system's composites and reading and writing through `call` and `query`. It
//! writes nothing: its files go into `plugins/<name>/` of a site's folder on a computer,
//! where the `publr` command builds them (`publr plugin build --name <name>`).
const std = @import("std");
const public = @import("../../publr/operations/plugin/scaffold.zig");
const sdk = @import("../../sdk.zig");
const plugin_model = @import("../../model/sandboxed_plugin.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{Scaffold};

pub const Shape = public.Shape;

pub const Source = public.Source;

const icons_list = "x-close\nchevron-up\nchevron-down\nlist-unordered\n";

pub const Scaffold = struct {
    pub const shape = public.Scaffold;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        if (!plugin_model.valid_name(in.name)) {
            return error.Invalid;
        }

        return .{
            .files = try files_of(ctx.arena, in.name, in.page),
        };
    }
};

fn files_of(arena: std.mem.Allocator, name: []const u8, shape: Shape) Error![]const Source {
    std.debug.assert(name.len > 0);

    const pascal = try pascal_of(arena, name);
    var files: std.ArrayList(Source) = .empty;
    const main = if (shape == .list)
        @embedFile("scaffold/list_main.zig.txt")
    else
        @embedFile("scaffold/form_main.zig.txt");
    try add(arena, &files, "main.zig", try filled(arena, main, name, pascal));

    // A form is a declaration the admin draws; a list draws itself, in the plugin frame.
    if (shape == .list) {
        const page = try filled(arena, @embedFile("scaffold/list_page.ptsx.txt"), name, pascal);

        try add(arena, &files, try path_of(arena, pascal, "Page"), page);
        try add(arena, &files, "ui/icons.txt", icons_list);
    }

    return files.items;
}

fn add(
    arena: std.mem.Allocator,
    files: *std.ArrayList(Source),
    path: []const u8,
    content: []const u8,
) Error!void {
    std.debug.assert(path.len > 0);

    files.append(arena, .{
        .path = path,
        .content = content,
    }) catch return error.OutOfMemory;
}

fn path_of(arena: std.mem.Allocator, pascal: []const u8, part: []const u8) Error![]const u8 {
    std.debug.assert(pascal.len > 0);

    return std.fmt.allocPrint(arena, "ui/{s}{s}.ptsx", .{ pascal, part }) catch error.OutOfMemory;
}

/// `guest_book` as `GuestBook`: the plugin's views are named after it.
fn pascal_of(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    std.debug.assert(name.len > 0);

    var out: std.ArrayList(u8) = .empty;
    var upper = true;

    for (name) |char| {
        if (char == '_') {
            upper = true;
            continue;
        }

        out.append(arena, if (upper) std.ascii.toUpper(char) else char) catch {
            return error.OutOfMemory;
        };
        upper = false;
    }

    return out.items;
}

/// `guest_book` as `Guest book`: what people read in labels and headings.
fn title_of(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    std.debug.assert(name.len > 0);

    const title = arena.dupe(u8, name) catch return error.OutOfMemory;

    std.mem.replaceScalar(u8, title, '_', ' ');
    title[0] = std.ascii.toUpper(title[0]);

    return title;
}

fn filled(
    arena: std.mem.Allocator,
    template: []const u8,
    name: []const u8,
    pascal: []const u8,
) Error![]const u8 {
    std.debug.assert(template.len > 0);

    const title = try title_of(arena, name);
    const titled = std.mem.replaceOwned(u8, arena, template, "__Title__", title) catch {
        return error.OutOfMemory;
    };
    const named = std.mem.replaceOwned(u8, arena, titled, "__name__", name) catch {
        return error.OutOfMemory;
    };

    return std.mem.replaceOwned(u8, arena, named, "__Name__", pascal) catch error.OutOfMemory;
}

test "a starter names its files and code after the plugin" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = try files_of(arena, "guest_book", .list);

    try std.testing.expectEqualStrings("ui/GuestBookPage.ptsx", files[1].path);
    try std.testing.expectEqualStrings("ui/icons.txt", files[2].path);
    try std.testing.expect(std.mem.indexOf(u8, files[0].content, ".name = \"guest_book\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, files[0].content, "__") == null or
        std.mem.indexOf(u8, files[0].content, "__name__") == null);
    const form = try files_of(arena, "guest_book", .form);

    try std.testing.expect(std.mem.indexOf(u8, files[1].content, "\"guest_book.add\"") != null);
    // Drawn on the design system, installed or compiled in alike.
    try std.testing.expect(std.mem.indexOf(u8, files[1].content, "class=") == null);
    try std.testing.expect(std.mem.indexOf(u8, files[0].content, "publr.views.render(") != null);
    try std.testing.expect(std.mem.indexOf(u8, files[0].content, "\"Guest book\"") != null);
    try std.testing.expectEqual(@as(usize, 1), form.len);
    try std.testing.expect(std.mem.indexOf(u8, form[0].content, ".form = .{") != null);
}
