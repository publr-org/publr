//! A plugin built from sources an agent sends, for one with no file system of its own: the
//! files written into the project's `plugins/<name>/`, then the same `publr plugin build` an
//! agent next to the project runs, in a process of its own; `build_log` says how it went.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const file_path = @import("../../model/app/file_path.zig");
const plugin_model = @import("../../model/sandboxed_plugin.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const files_max: u32 = 64;
pub const log_bytes_max: u32 = 256 << 10;

pub const operations = [_]type{ Build, BuildLog };

pub const Source = struct { path: []const u8, content: []const u8 };

pub const Build = struct {
    pub const name = "plugin.build";
    pub const description = "Write a plugin's sources and build it; it installs when built";
    pub const details =
        \\Administrators only, while `publr serve` runs a binary that carries the compiler.
        \\Each file goes to `plugins/<name>/<path>` (`main.zig` is the plugin); files left
        \\out stay as they are. The build runs on its own and takes a while: follow it with
        \\`plugin build_log`. Built, the plugin is added and enabled, or updated when it was
        \\there; what it asks for is granted by tier and high requests wait for a person.
        \\It changes what the site does, so a device that may save drafts only is refused.
        \\Next to the project, edit the files and run `publr plugin build --name <name>`.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { name: []const u8, files: []const Source };
    pub const Out = struct { started: bool, log: []const u8 };
    pub const example: In = .{ .name = "guestbook", .files = &.{.{
        .path = "main.zig",
        .content = "const publr = @import(\"publr\");\n",
    }} };
    pub const example_out: Out = .{ .started = true, .log = "data/builds/guestbook.log" };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The plugin's name, `[a-z][a-z0-9_]*`",
        .files = "Up to 64 files as `{ path, content }`, paths inside the plugin's folder",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .started = "Always true",
        .log = "Where the build writes what it did",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const builder = ctx.builder orelse return error.Unavailable;

        if (!plugin_model.valid_name(in.name) or in.files.len > files_max) {
            return error.Invalid;
        }

        try check_files(ctx, in);
        ctx.notice("plugin.published", in.name);

        if (ctx.caller.scope() == .drafts) {
            return ctx.fail(sdk.operation.drafts_only);
        }

        try write_files(ctx, builder, in);

        if (builder.start(builder.context, in.name)) |problem| {
            std.log.warn("plugin build {s}: {s}", .{ in.name, problem });

            return error.Unavailable;
        }

        const log = std.fmt.allocPrint(ctx.arena, "{s}/{s}.log", .{ builder.logs_dir, in.name });

        return .{ .started = true, .log = log catch return error.OutOfMemory };
    }

    fn check_files(ctx: *Ctx, in: In) Error!void {
        std.debug.assert(in.files.len <= files_max);

        for (in.files) |file| {
            const whole = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ in.name, file.path });
            const path = whole catch return error.OutOfMemory;

            if (!file_path.valid(path) or !std.unicode.utf8ValidateSlice(file.content)) {
                return error.Invalid;
            }

            if (file.content.len > file_path.bytes_max) {
                return error.TooBig;
            }
        }
    }

    fn write_files(ctx: *Ctx, builder: sdk.context.PluginBuilder, in: In) Error!void {
        std.debug.assert(builder.plugins_dir.len > 0);

        const cwd = std.Io.Dir.cwd();
        const folder = std.fs.path.join(ctx.arena, &.{ builder.plugins_dir, in.name }) catch {
            return error.OutOfMemory;
        };

        cwd.createDirPath(ctx.io, folder) catch return error.Unavailable;

        var root = cwd.openDir(ctx.io, folder, .{}) catch return error.Unavailable;
        defer root.close(ctx.io);

        for (in.files) |file| {
            if (std.fs.path.dirname(file.path)) |dir| {
                root.createDirPath(ctx.io, dir) catch return error.Unavailable;
            }

            root.writeFile(ctx.io, .{ .sub_path = file.path, .data = file.content }) catch {
                return error.Unavailable;
            };
        }
    }
};

pub const BuildLog = struct {
    pub const name = "plugin.build_log";
    pub const description = "What the last build of a plugin did";
    pub const details =
        \\Administrators only. The compiler's messages, then what installing answered; empty
        \\while the build has written nothing yet. Not found before any build.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { name: []const u8 };
    pub const Out = struct { log: []const u8 };
    pub const example: In = .{ .name = "guestbook" };
    pub const example_out: Out = .{ .log = "{\n  \"enabled\": [\"guestbook\"]\n}\n" };
    pub const field_docs: sdk.operation.Docs(In) = .{ .name = "The plugin's name" };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .log = "Up to its last 256 KiB" };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const builder = ctx.builder orelse return error.Unavailable;

        if (!plugin_model.valid_name(in.name)) {
            return error.Invalid;
        }

        std.debug.assert(builder.logs_dir.len > 0);

        const path = std.fmt.allocPrint(ctx.arena, "{s}/{s}.log", .{ builder.logs_dir, in.name });
        const limit: std.Io.Limit = .limited(log_bytes_max);
        const cwd = std.Io.Dir.cwd();
        const where = path catch return error.OutOfMemory;
        const log = cwd.readFileAlloc(ctx.io, where, ctx.arena, limit);

        return .{ .log = log catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unavailable,
        } };
    }
};
