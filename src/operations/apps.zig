const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/apps.zig");
const trash = @import("trash.zig");
const file_path = @import("../model/app/file_path.zig");
const key_page = @import("../model/key_page.zig");
const file_content = @import("../model/app/file_content.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const files_max: u32 = 4096;

pub const namespace = public.namespace;

pub const operations = [_]type{ Files, Read, Write, Remove, Load, @import("apps/edit.zig").Edit };

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

    return cwd.openDir(ctx.io, folder.dir, .{
        .iterate = true,
    }) catch |err| {
        return if (err == error.FileNotFound) error.NotFound else error.Unavailable;
    };
}

pub const Entry = public.Entry;

pub const Files = struct {
    pub const shape = public.Files;
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
        if (in.prefix.len > file_path.len_max or in.after.len > file_path.len_max) {
            return error.Invalid;
        }

        var root = open_root(ctx, try folder_of(ctx), false) catch |err| {
            return if (err == error.NotFound) .{
                .files = &.{},
            } else err;
        };
        defer root.close(ctx.io);

        var found: std.ArrayList(Entry) = .empty;
        var walker = root.walk(ctx.arena) catch return error.OutOfMemory;
        defer walker.deinit();

        while (walker.next(ctx.io) catch return error.Unavailable) |item| {
            const wanted = std.mem.startsWith(u8, item.path, in.prefix);

            if (item.kind != .file or !file_path.valid(item.path) or !wanted) {
                continue;
            }

            if (found.items.len == files_max) {
                break;
            }

            const path = ctx.arena.dupe(u8, item.path) catch return error.OutOfMemory;

            found.append(ctx.arena, .{
                .path = path,
                .bytes = 0,
            }) catch {
                return error.OutOfMemory;
            };
        }

        std.mem.sort(Entry, found.items, {}, earlier);
        std.debug.assert(found.items.len <= files_max);

        const paths = ctx.arena.alloc([]const u8, found.items.len) catch {
            return error.OutOfMemory;
        };

        for (found.items, paths) |entry, *path| {
            path.* = entry.path;
        }

        const page = key_page.window(paths, in.after, sdk.operation.page_limit_max);
        const files = found.items[page.start..page.end];

        // Only the page's files are looked at for their size.
        for (files) |*entry| {
            const stat = root.statFile(ctx.io, entry.path, .{}) catch continue;

            entry.bytes = stat.size;
        }

        return .{
            .files = files,
            .next = page.next,
        };
    }

    fn earlier(_: void, left: Entry, right: Entry) bool {
        return std.mem.lessThan(u8, left.path, right.path);
    }
};

pub const Read = struct {
    pub const shape = public.Read;
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

        const sent = try file_content.carried(ctx.arena, content);

        return .{
            .path = in.path,
            .content = sent.content,
            .encoding = sent.encoding,
        };
    }
};

pub const Write = struct {
    pub const shape = public.Write;
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
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!file_path.valid(in.path)) {
            return error.Invalid;
        }

        const bytes = try file_content.bytes_of(ctx.arena, in.content, in.encoding);

        // An app file is live once loaded: the call publishes, and a drafts device is refused
        // here, before anything reaches the folder, not only at commit.
        ctx.publishes = true;
        try refuse_drafts(ctx);

        var root = try open_root(ctx, try folder_of(ctx), true);
        defer root.close(ctx.io);

        if (std.fs.path.dirname(in.path)) |dir| {
            root.createDirPath(ctx.io, dir) catch return error.Unavailable;
        }

        root.writeFile(ctx.io, .{
            .sub_path = in.path,
            .data = bytes,
        }) catch {
            return error.Unavailable;
        };

        return .{
            .path = in.path,
            .bytes = bytes.len,
        };
    }
};

/// The files themselves are not in the transaction: a write a device may not make is
/// refused before it touches them.
fn refuse_drafts(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.publishes);

    if (ctx.drafts_only()) {
        return ctx.fail(sdk.operation.drafts_only);
    }
}

/// An app file the trash keeps, at most: its text.
const file_bytes_kept_max: u32 = 1 << 20;

pub const Remove = struct {
    pub const shape = public.Remove;
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
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!file_path.valid(in.path)) {
            return error.Invalid;
        }

        ctx.publishes = true;
        try refuse_drafts(ctx);

        var root = try open_root(ctx, try folder_of(ctx), false);
        defer root.close(ctx.io);

        // What it held waits in the trash, as the call that writes it back.
        const limit: std.Io.Limit = .limited(file_bytes_kept_max);
        const held = root.readFileAlloc(ctx.io, in.path, ctx.arena, limit) catch |err| {
            return if (err == error.FileNotFound) error.NotFound else error.Unavailable;
        };
        const kept = try file_content.carried(ctx.arena, held);
        const copy = std.json.Stringify.valueAlloc(ctx.arena, .{
            .path = in.path,
            .content = kept.content,
            .encoding = kept.encoding,
        }, .{}) catch return error.OutOfMemory;

        _ = try trash.keep(ctx, .{
            .kind = "app_file",
            .key = in.path,
            .label = std.fmt.allocPrint(ctx.arena, "App file {s}", .{in.path}) catch {
                return error.OutOfMemory;
            },
            .copy = copy,
        });

        root.deleteFile(ctx.io, in.path) catch |err| {
            return if (err == error.FileNotFound) error.NotFound else error.Unavailable;
        };

        return .{
            .removed = true,
        };
    }
};

pub const Load = struct {
    pub const shape = public.Load;
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

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        const folder = try folder_of(ctx);

        std.debug.assert(ctx.db.transaction_depth == 0);

        const problem = folder.reload(folder.context) orelse return .{
            .loaded = true,
        };
        const message = ctx.arena.dupe(u8, problem) catch return error.OutOfMemory;

        return ctx.fail(.{
            .name = "NotLoaded",
            .status = 422,
            .message = message,
        });
    }
};
