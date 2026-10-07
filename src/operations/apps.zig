//! The project's apps as files, for an agent with no file system of its own (a chat app over
//! MCP): list them, read one, write one, remove one, then load them into the running server.
//! An agent next to the project edits `apps/` directly and runs `publr apps load`.

const std = @import("std");
const sdk = @import("../sdk.zig");
const file_path = @import("../model/app/file_path.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const files_max: u32 = 4096;

pub const namespace: sdk.operation.Namespace = .{
    .name = "apps",
    .summary = "The project's apps as files, for agents with no file system",
    .details =
    \\Each app is a folder in the project's `apps/` (`apps/<name>/app.zon` and its
    \\templates). `apps files` lists them, `apps read` and `apps write` take one file as
    \\text, `apps remove` deletes one, and `apps load` reads them into the running server,
    \\answering why they do not load when they do not. A write changes the live site, so
    \\a device allowed only drafts may not make one. Administrators only. With `publr
    \\serve` running they act on its apps, else on the project's `apps/`.
    ,
};

pub const operations = [_]type{ Files, Read, Write, Remove, Load };

/// The apps folder of the running server; `Unavailable` with none.
fn folder_of(ctx: *const Ctx) Error!sdk.context.AppsFolder {
    std.debug.assert(ctx.now_ms >= 0);

    const folder = ctx.apps orelse return error.Unavailable;

    std.debug.assert(folder.dir.len > 0);

    return folder;
}

/// The folder opened; made first for a write, `NotFound` for a read when there is none yet.
fn open_root(ctx: *const Ctx, folder: sdk.context.AppsFolder, make: bool) Error!std.Io.Dir {
    std.debug.assert(folder.dir.len > 0);

    const cwd = std.Io.Dir.cwd();

    if (make) {
        cwd.createDirPath(ctx.io, folder.dir) catch return error.Unavailable;
    }

    return cwd.openDir(ctx.io, folder.dir, .{ .iterate = true }) catch |err| {
        return if (err == error.FileNotFound) error.NotFound else error.Unavailable;
    };
}

pub const Entry = struct { path: []const u8, bytes: u64 };

pub const Files = struct {
    pub const name = "apps.files";
    pub const description = "Every file of the project's apps";
    pub const details = "Administrators only. Paths are `<app>/<path>`, sorted.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { files: []const Entry };
    pub const example: In = .{};
    pub const example_out: Out = .{ .files = &.{
        .{ .path = "www/app.zon", .bytes = 112 },
        .{ .path = "www/content/index.publr", .bytes = 640 },
    } };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{ .files = "Up to 4096 files" };

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        var root = open_root(ctx, try folder_of(ctx), false) catch |err| {
            return if (err == error.NotFound) .{ .files = &.{} } else err;
        };
        defer root.close(ctx.io);

        var found: std.ArrayList(Entry) = .empty;
        var walker = root.walk(ctx.arena) catch return error.OutOfMemory;
        defer walker.deinit();

        while (walker.next(ctx.io) catch return error.Unavailable) |item| {
            if (item.kind != .file or !file_path.valid(item.path)) {
                continue;
            }

            if (found.items.len == files_max) {
                break;
            }

            const stat = root.statFile(ctx.io, item.path, .{}) catch continue;
            const path = ctx.arena.dupe(u8, item.path) catch return error.OutOfMemory;

            found.append(ctx.arena, .{ .path = path, .bytes = stat.size }) catch {
                return error.OutOfMemory;
            };
        }

        std.mem.sort(Entry, found.items, {}, earlier);
        std.debug.assert(found.items.len <= files_max);

        return .{ .files = found.items };
    }

    fn earlier(_: void, left: Entry, right: Entry) bool {
        return std.mem.lessThan(u8, left.path, right.path);
    }
};

pub const Read = struct {
    pub const name = "apps.read";
    pub const description = "One file of the project's apps, as text";
    pub const details = "Administrators only. Not found when there is no such file.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { path: []const u8 };
    pub const Out = struct { path: []const u8, content: []const u8 };
    pub const example: In = .{ .path = "www/content/index.publr" };
    pub const example_out: Out = .{ .path = "www/content/index.publr", .content = "<h1>Hi</h1>\n" };
    pub const field_docs: sdk.operation.Docs(In) = .{ .path = "`<app>/<path>`" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .path = "The file",
        .content = "What it holds, up to 1 MiB",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        if (!file_path.valid(in.path)) {
            return error.Invalid;
        }

        var root = try open_root(ctx, try folder_of(ctx), false);
        defer root.close(ctx.io);

        const limit: std.Io.Limit = .limited(file_path.bytes_max);
        const content = root.readFileAlloc(ctx.io, in.path, ctx.arena, limit) catch |err| {
            return switch (err) {
                error.FileNotFound => error.NotFound,
                error.OutOfMemory => error.OutOfMemory,
                error.StreamTooLong => error.TooBig,
                else => error.Unavailable,
            };
        };

        std.debug.assert(content.len <= file_path.bytes_max);

        return .{ .path = in.path, .content = content };
    }
};

pub const Write = struct {
    pub const name = "apps.write";
    pub const description = "Write one file of the project's apps; `apps load` makes it live";
    pub const details =
        \\Administrators only. Creates the file and its folders, or replaces it. The text is
        \\up to 1 MiB of UTF-8. It changes what visitors see once loaded, so a device that
        \\may save drafts only is refused.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { path: []const u8, content: []const u8 };
    pub const Out = struct { path: []const u8, bytes: u64 };
    pub const example: In = .{ .path = "www/content/index.publr", .content = "<h1>Hi</h1>\n" };
    pub const example_out: Out = .{ .path = "www/content/index.publr", .bytes = 12 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .path = "`<app>/<path>`",
        .content = "The whole file, as text",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .path = "The file",
        .bytes = "Its size",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!file_path.valid(in.path) or !std.unicode.utf8ValidateSlice(in.content)) {
            return error.Invalid;
        }

        if (in.content.len > file_path.bytes_max) {
            return error.TooBig;
        }

        // Written before the drafts check runs at commit: noticed first, so a drafts device
        // is refused before anything reaches the folder.
        ctx.notice("apps.published", in.path);
        try refuse_drafts(ctx);

        var root = try open_root(ctx, try folder_of(ctx), true);
        defer root.close(ctx.io);

        if (std.fs.path.dirname(in.path)) |dir| {
            root.createDirPath(ctx.io, dir) catch return error.Unavailable;
        }

        root.writeFile(ctx.io, .{ .sub_path = in.path, .data = in.content }) catch {
            return error.Unavailable;
        };

        return .{ .path = in.path, .bytes = in.content.len };
    }
};

/// The files themselves are not in the transaction: a write a drafts device may not make is
/// refused before it touches them.
fn refuse_drafts(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.publishes);

    const scope = ctx.caller.scope() orelse return;

    if (scope == .drafts) {
        return ctx.fail(sdk.operation.drafts_only);
    }
}

pub const Remove = struct {
    pub const name = "apps.remove";
    pub const description = "Delete one file of the project's apps";
    pub const details =
        \\Administrators only, and not a device that may save drafts only. Not found when
        \\there is no such file. `apps load` makes the change live.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { path: []const u8 };
    pub const Out = struct { removed: bool };
    pub const example: In = .{ .path = "www/content/old.publr" };
    pub const example_out: Out = .{ .removed = true };
    pub const field_docs: sdk.operation.Docs(In) = .{ .path = "`<app>/<path>`" };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .removed = "Always true" };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!file_path.valid(in.path)) {
            return error.Invalid;
        }

        ctx.notice("apps.published", in.path);
        try refuse_drafts(ctx);

        var root = try open_root(ctx, try folder_of(ctx), false);
        defer root.close(ctx.io);

        root.deleteFile(ctx.io, in.path) catch |err| {
            return if (err == error.FileNotFound) error.NotFound else error.Unavailable;
        };

        return .{ .removed = true };
    }
};

pub const Load = struct {
    pub const name = "apps.load";
    pub const description = "Read the apps from their folder into the running server";
    pub const details =
        \\Administrators only. The apps are read again and swapped in, live at once; with
        \\no server running, they are only checked, as `serve` would load them. When they
        \\do not load, the failure says why, and a running server's apps are unavailable
        \\(the admin stays up) until a load succeeds.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { loaded: bool };
    pub const example: In = .{};
    pub const example_out: Out = .{ .loaded = true };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{ .loaded = "Always true" };

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        const folder = try folder_of(ctx);

        std.debug.assert(ctx.db.transaction_depth == 0);

        const problem = folder.reload(folder.context) orelse return .{ .loaded = true };
        const message = ctx.arena.dupe(u8, problem) catch return error.OutOfMemory;

        return ctx.fail(.{ .name = "NotLoaded", .status = 422, .message = message });
    }
};
