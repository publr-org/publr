const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const embed = @import("apps/embed.zig");

pub const dir_default = "apps";
pub const apps_max_default: u32 = 32;
pub const name_len_max: u32 = 32;

/// Every app under `dir`, compiled in as the `apps` module the library imports: its
/// templates as text, its generated client code, its interactive components lowered to Zig,
/// its `middleware.zig` and its `app.zon`. No folder, no apps.
pub fn add(
    builder: *std.Build,
    library: *std.Build.Module,
    runtime: *std.Build.Module,
    pjsx_gen: *std.Build.Step.Compile,
    dir: []const u8,
    apps_max: u32,
) void {
    std.debug.assert(dir.len > 0);
    std.debug.assert(apps_max > 0);

    const names = discover(builder, dir, apps_max);
    var source: std.ArrayList(u8) = .empty;

    append(builder, &source, "pub const all = .{\n");

    for (names) |name| {
        append(builder, &source, builder.fmt("    @import(\"app_{s}\"),\n", .{name}));
    }

    append(builder, &source, "};\n");

    const listing = builder.addWriteFiles().add("apps.zig", source.items);
    const module = builder.createModule(.{
        .root_source_file = listing,
        .target = library.resolved_target,
        .optimize = library.optimize,
    });

    for (names) |name| {
        const app = app_module(builder, library, runtime, pjsx_gen, dir, name);

        module.addImport(builder.fmt("app_{s}", .{name}), app);
    }

    library.addImport("apps", module);
}

const root_format =
    \\const publr = @import("publr");
    \\
    \\pub const name = "{s}";
    \\pub const config: publr.model.app.Config = @import("app_zon");
    \\pub const templates = @import("app_templates").files;
    \\pub const assets = @import("app_assets").files;
    \\pub const interactive = @import("app_interactive");
    \\pub const middleware = @import("app_middleware");
    \\pub const style_css = @embedFile("app_style_css");
    \\pub const interactive_classes = @embedFile("app_interactive_classes");
    \\
;

/// One app as a module: its declarations over the generated parts, and `publr` for the
/// type `app.zon` is read as.
fn app_module(
    builder: *std.Build,
    library: *std.Build.Module,
    runtime: *std.Build.Module,
    pjsx_gen: *std.Build.Step.Compile,
    dir: []const u8,
    name: []const u8,
) *std.Build.Module {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= name_len_max);

    const app_dir = builder.pathJoin(&.{ dir, name });
    const placeholders = builder.addWriteFiles();
    // A folder of its own per app: two apps' identical stand-ins would otherwise be one
    // file in two modules, which the compiler refuses.
    _ = placeholders.add("app.txt", app_dir);
    const interactive = embed.interactive(builder, runtime, pjsx_gen, app_dir, placeholders);
    const style = embed.optional_file(builder, placeholders, app_dir, "public/style.css", "");
    const root = builder.addWriteFiles().add("app.zig", builder.fmt(root_format, .{name}));
    const module = builder.createModule(.{
        .root_source_file = root,
        .target = library.resolved_target,
        .optimize = library.optimize,
    });

    module.addImport("publr", library);
    module.addAnonymousImport("app_zon", .{
        .root_source_file = builder.path(builder.pathJoin(&.{ app_dir, "app.zon" })),
    });
    module.addImport("app_templates", embed.templates(builder, app_dir));
    module.addImport("app_assets", embed.assets(builder, app_dir, interactive.stores));
    module.addImport("app_interactive", interactive.module);
    module.addImport("app_middleware", middleware(builder, library, app_dir));
    module.addAnonymousImport("app_style_css", .{ .root_source_file = style });
    module.addAnonymousImport("app_interactive_classes", .{
        .root_source_file = interactive.classes,
    });

    return module;
}

/// The app's `middleware.zig`, compiled in: it imports `publr` and every compiled-in plugin
/// by name. An app without one gets an empty stand-in, and nothing runs.
fn middleware(
    builder: *std.Build,
    library: *std.Build.Module,
    app_dir: []const u8,
) *std.Build.Module {
    std.debug.assert(app_dir.len > 0);
    std.debug.assert(library.root_source_file != null);

    const path = builder.pathJoin(&.{ app_dir, "middleware.zig" });
    const root = if (builder.build_root.handle.access(builder.graph.io, path, .{})) |_|
        builder.path(path)
    else |_|
        builder.addWriteFiles().add("middleware.zig", builder.fmt(
            "//! {s} has no middleware.\n",
            .{app_dir},
        ));
    const module = builder.createModule(.{
        .root_source_file = root,
        .target = library.resolved_target,
        .optimize = library.optimize,
    });
    const plugins = library.import_table.get("plugins") orelse @panic("plugins not added");

    module.addImport("publr", library);

    for (plugins.import_table.keys(), plugins.import_table.values()) |name, plugin| {
        module.addImport(name, plugin);
    }

    return module;
}

/// The apps under `dir`, sorted: every folder (or link to one) with a valid name. Each
/// must carry its `app.zon`, which says where it is mounted.
fn discover(builder: *std.Build, dir: []const u8, apps_max: u32) []const []const u8 {
    std.debug.assert(dir.len > 0);
    std.debug.assert(apps_max > 0);

    const io = builder.graph.io;
    var root = builder.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch {
        if (!std.mem.eql(u8, dir, dir_default)) {
            diagnostic.fail("-Dapps: no folder at {s}", .{dir});
        }

        return &.{};
    };
    defer root.close(io);

    var iterator = root.iterate();
    var found: std.ArrayList([]const u8) = .empty;

    while (iterator.next(io) catch null) |entry| {
        const folder = entry.kind == .directory or entry.kind == .sym_link;

        if (!folder or std.mem.startsWith(u8, entry.name, ".")) {
            continue;
        }

        if (!valid_name(entry.name)) {
            diagnostic.fail("{s}/{s}: an app's folder is [a-z][a-z0-9_]*, 1 to 32 characters", .{
                dir,
                entry.name,
            });
        }

        root.access(io, builder.fmt("{s}/app.zon", .{entry.name}), .{}) catch
            diagnostic.fail("{s}/{s}: no app.zon; it says where the app is mounted", .{
                dir,
                entry.name,
            });

        if (found.items.len == apps_max) {
            diagnostic.fail("{s}: more than {d} apps; raise -Dapps-max", .{ dir, apps_max });
        }

        found.append(builder.allocator, builder.dupe(entry.name)) catch @panic("OOM");
    }

    std.mem.sort([]const u8, found.items, {}, less_than);

    return found.items;
}

fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max or name[0] < 'a' or name[0] > 'z') {
        return false;
    }

    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= '0' and char <= '9') or char == '_';

        if (!ok) {
            return false;
        }
    }

    return true;
}

/// The built binary compiles its own apps (`publr check-apps`), so a template the engine
/// refuses fails `zig build`, not the first start. A binary for another machine cannot run
/// here: it is checked where it runs.
pub fn add_check(
    builder: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    std.debug.assert(exe.kind == .exe);
    std.debug.assert(builder.build_root.path != null);

    if (!target.query.isNative()) {
        return;
    }

    const check = builder.addRunArtifact(exe);

    check.addArg("check-apps");
    check.expectExitCode(0);
    builder.getInstallStep().dependOn(&check.step);
}

fn append(builder: *std.Build, source: *std.ArrayList(u8), text: []const u8) void {
    std.debug.assert(text.len > 0);
    std.debug.assert(source.items.len < 1 << 20);

    source.appendSlice(builder.allocator, text) catch @panic("OOM");
}

fn less_than(_: void, left: []const u8, right: []const u8) bool {
    std.debug.assert(left.len > 0);
    std.debug.assert(right.len > 0);

    return std.mem.lessThan(u8, left, right);
}
