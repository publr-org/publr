//! An app's stylesheet and its class book, made when the app loads: every declaration of
//! the classes its templates and interactive components name gets a short name, and the
//! sheet styles them by those names. Pages write their classes through the book; the
//! browser gets it as `class-book.js`, imported before the stores.
const std = @import("std");
const jit = @import("publr_jit");
const engine = @import("../../template.zig");
const spec_module = @import("spec.zig");

const Spec = spec_module.Spec;

const preflight_css = @embedFile("apps_preflight_css");

/// The module the browser installs the book from, beside `stores.js`.
pub const script_path = "class-book.js";

pub const Sheet = struct {
    /// Preflight, the app's own `style.css`, then the utilities; owned by the `gpa` given.
    css: []const u8,
    /// Owned by the arena given.
    book: jit.Book,
};

/// The sheet and the book for `spec`'s templates (`program`) and interactive components.
pub fn compile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    spec: *const Spec,
    program: ?*const engine.Program,
) !Sheet {
    std.debug.assert(preflight_css.len > 0);
    std.debug.assert(spec.name.len > 0);

    var classes: std.ArrayList([]const u8) = .empty;
    var reserved: std.ArrayList([]const u8) = .empty;

    if (program) |loaded| {
        try classes.appendSlice(arena, loaded.classes);
    }

    var tokens = std.mem.tokenizeAny(u8, spec.interactive_classes, " \t\r\n");

    while (tokens.next()) |class| {
        try classes.append(arena, class);
    }

    // The app's own CSS and the preflight select classes by their names: no short name
    // may be one of them.
    try jit.book.selectedClasses(arena, spec.style_css, &reserved);
    try jit.book.selectedClasses(arena, preflight_css, &reserved);

    const book = try jit.book.build(gpa, arena, spec.tokens, .{
        .classes = classes.items,
        .reserved = reserved.items,
    });
    const utilities = try jit.compileBook(arena, spec.tokens, &book, .{
        .minify = spec_module.minify,
    });
    const separator: []const u8 = if (spec_module.minify) "" else "\n";
    const parts = [_][]const u8{ preflight_css, separator, spec.style_css, separator, utilities };

    return .{
        .css = try std.mem.concat(gpa, u8, &parts),
        .book = book,
    };
}

/// `class-book.js`: the book installed in PublrJS's merge, owned by `arena`.
pub fn script(arena: std.mem.Allocator, book: *const jit.Book) ![]const u8 {
    std.debug.assert(book.atom_starts.len == book.classes.len + 1);

    var out: std.Io.Writer.Allocating = .init(arena);

    try jit.book.writeScript(book, &out.writer, "./publr-class-merge.js");

    std.debug.assert(out.written().len > 0);

    return out.written();
}
