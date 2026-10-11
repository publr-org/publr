//! The admin stylesheet: the JIT (a path dependency) over the classes the generated
//! views use, themed by `ui/styles/theme.zon` over `ui/styles/base.css`'s palette, with the JIT's
//! preflight ahead of everything. Embedded into the app as `styles_css` and served
//! at `/admin/styles.css`. Minified except in Debug builds.
const std = @import("std");

/// Every `listed("…")` in `src/`, one class per line: what Zig code hands the views.
fn listed_classes(builder: *std.Build) std.Build.LazyPath {
    std.debug.assert(builder.build_root.path != null);

    const io = builder.graph.io;
    var dir = builder.build_root.handle.openDir(io, "src", .{
        .iterate = true,
    }) catch @panic("src/ is missing");
    defer dir.close(io);

    var walker = dir.walk(builder.allocator) catch @panic("OOM");
    defer walker.deinit();

    var out: std.ArrayList(u8) = .empty;
    const call = "listed(\"";

    while (walker.next(io) catch @panic("cannot walk src/")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) {
            continue;
        }

        const text = dir.readFileAlloc(io, entry.path, builder.allocator, .limited(4 << 20)) catch
            @panic("cannot read src/");
        var at: usize = 0;

        while (std.mem.indexOfPos(u8, text, at, call)) |found| {
            const start = found + call.len;
            const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse break;
            const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..found], '\n')) |nl|
                nl + 1
            else
                0;
            const line = std.mem.trimStart(u8, text[line_start..found], " ");

            at = end;

            // A comment naming the helper names no class.
            if (std.mem.startsWith(u8, line, "//")) {
                continue;
            }

            out.appendSlice(builder.allocator, text[start..end]) catch @panic("OOM");
            out.append(builder.allocator, '\n') catch @panic("OOM");
        }
    }

    return builder.addWriteFiles().add("listed_classes.txt", out.items);
}

/// The admin's class book: every class and every stack the views can write, named.
pub const Book = struct {
    /// The book as Zig, for the server's merge (`src/ui/class_merge.zig`).
    zig: std.Build.LazyPath,
    /// The book as JSON, for the browser's (`/admin/classes.json`).
    json: std.Build.LazyPath,
};

pub fn add(
    builder: *std.Build,
    module: *std.Build.Module,
    classes: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode,
) Book {
    std.debug.assert(module.root_source_file != null);
    std.debug.assert(builder.build_root.path != null);

    const jit = builder.dependency("publr_jit", .{
        .target = builder.graph.host,
    });
    const run = builder.addRunArtifact(jit.artifact("jit"));

    // Every declaration is written by its short name.
    run.addArg("book");
    const book_zig = run.addPrefixedOutputFileArg("--zig=", "class_book.zig");
    const book_json = run.addPrefixedOutputFileArg("--json=", "class_book.json");

    run.addPrefixedFileArg("--theme=", builder.path("ui/styles/theme.zon"));
    run.addPrefixedFileArg("--prepend=", jit.path("src/preflight.css"));
    run.addPrefixedFileArg("--prepend=", builder.path("ui/styles/base.css"));

    if (optimize == .Debug) {
        run.addArg("--no-minify");
    }

    run.addFileArg(classes);
    // The block editor's chrome joins the admin's stylesheet: one sheet, no second one.
    const editor = builder.dependency("publr_editor", .{}).namedLazyPath("admin");

    run.addFileArg(editor.path(builder, "classes.txt"));
    // The classes Zig code names, each through `class_merge.listed("…")`.
    run.addFileArg(listed_classes(builder));

    const css = run.captureStdOut(.{});

    module.addAnonymousImport("styles_css", .{
        .root_source_file = css,
    });
    module.addAnonymousImport("admin_class_book_json", .{
        .root_source_file = book_json,
    });

    return .{
        .zig = book_zig,
        .json = book_json,
    };
}
