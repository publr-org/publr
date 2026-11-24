//! Files a plugin makes (an invoice's PDF, a label, a feed, a CSV export): written in pieces,
//! so the plugin never holds the whole file, then kept as a file of one of its own media
//! types, a published record it references like any other. A file of a private media type
//! opens only to whoever may read the type (staff), or to whoever holds a link the plugin
//! signed (`/_links/<token>` answering `{ "file": <id> }`); it attaches to messages as any
//! file does. How large a file may be is the plugin's declared limit (`.limits.file_mib`,
//! granted with the plugin), never more than the site keeps.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const files_module = @import("../../lib/files.zig");
const library = @import("library.zig");
const upload = @import("upload.zig");
const content_types = @import("../content_type.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const media = model.media;
const Base64 = std.base64.standard;

pub const operations = [_]type{ WritePart, Make, Made };

/// The most one piece carries, before base64: what a plugin holds at once.
pub const part_bytes_max: u32 = 256 << 10;
pub const part_name_len_min: u32 = 8;
pub const part_name_len_max: u32 = 40;
const part_prefix = "made-";

pub const WritePart = struct {
    pub const name = "media.write_part";
    pub const plugins_only = true;
    pub const description = "Add a piece to a file the plugin is making";
    pub const details =
        \\Plugins only. `data` (base64, at most 256 KiB before it) goes at `offset`: 0 starts
        \\the file afresh, any other must be where it ends. The part is the plugin's own; no
        \\other plugin writes or reads it. Past the plugin's file limit it is refused.
        \\`media.make` turns the part into a file.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        part: []const u8,
        offset: u64 = 0,
        data: []const u8,
    };
    pub const Out = struct {
        size: u64,
    };
    pub const example: In = .{
        .part = "invoice0001",
        .data = "JVBERi0xLjQK",
    };
    pub const example_out: Out = .{
        .size = 9,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .part = "The part's name, the plugin's own: 8 to 40 of a-z and 0-9",
        .offset = "Where the piece goes: 0 starts afresh, else the part's size so far",
        .data = "The piece's bytes, base64",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .size = "The part's size after the piece, in bytes",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const plugin = try plugin_of(ctx);
        const decoded_len = Base64.Decoder.calcSizeForSlice(in.data) catch return error.Invalid;

        if (decoded_len == 0 or decoded_len > part_bytes_max) {
            return error.Invalid;
        }

        if (in.offset + decoded_len > try file_bytes_max(ctx, plugin)) {
            return ctx.fail(too_large);
        }

        const bytes = try ctx.arena.alloc(u8, decoded_len);

        Base64.Decoder.decode(bytes, in.data) catch return error.Invalid;

        const files = try library.files_of(ctx);
        const key = try part_key(ctx, plugin, in.part);
        const size = files.append(.incoming, key, in.offset, bytes) catch |err| {
            return library.fail(err);
        };

        return .{
            .size = size,
        };
    }
};

pub const Make = struct {
    pub const name = "media.make";
    pub const plugins_only = true;
    pub const description = "Keep a part the plugin wrote as a file of one of its media types";
    pub const details =
        \\Plugins only. The part becomes a published file of `type`, a media type the plugin
        \\declares (`kind` `media`), named `filename` and checked as an upload is: its bytes
        \\must be what its extension says. A file of a private type opens only to whoever
        \\may read the type, or through a link the plugin signed. The part is gone after.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        part: []const u8,
        filename: []const u8,
        type: []const u8,
    };
    pub const Out = library.Item;
    pub const example: In = .{
        .part = "invoice0001",
        .filename = "invoice-FK-1.pdf",
        .type = "invoices.document",
    };
    pub const example_out: Out = library.example_item;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .part = "The part written with `media.write_part`",
        .filename = "The file's name, with its extension",
        .type = "One of the plugin's own media types, by handle",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const plugin = try plugin_of(ctx);

        if (!media.valid_filename(in.filename)) {
            return error.Invalid;
        }

        const def = (try library.media_type(ctx, in.type)).def;

        if (!std.mem.eql(u8, def.owner, plugin)) {
            return error.Denied;
        }

        const files = try library.files_of(ctx);
        const key = try part_key(ctx, plugin, in.part);
        const limit: u32 = @intCast(try file_bytes_max(ctx, plugin));
        const bytes = files.read(library.file_allocator, .incoming, key, limit) catch |err| {
            return library.fail(err);
        };
        defer library.file_allocator.free(bytes);

        if (bytes.len == 0) {
            return error.Invalid;
        }

        const item = try upload.add(ctx, files, def, in.filename, bytes, null);

        files.remove(.incoming, key);

        return item;
    }
};

pub const Made = struct {
    pub const name = "media.made";
    pub const plugins_only = true;
    pub const description = "A file the plugin made, by its id: where it is kept";
    pub const details =
        \\Plugins only, for the plugin's own files: what serving one through a signed link
        \\needs. A file of another plugin's type, or of none of its own, is not found.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        key: []const u8,
        filename: []const u8,
        mime_type: []const u8,
        size: u64,
    };
    pub const example: In = .{
        .id = library.example_item.id,
    };
    pub const example_out: Out = .{
        .key = "invoices.document/2026/11/invoice-fk-1-a1b2c3.pdf",
        .filename = "invoice-FK-1.pdf",
        .mime_type = "application/pdf",
        .size = 18_204,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The file's record id",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .key = "Where its bytes are kept",
        .filename = "Its name",
        .mime_type = "Its type",
        .size = "Its size in bytes",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const plugin = try plugin_of(ctx);

        if (in.id.len == 0 or in.id.len > store.records.id_len) {
            return error.NotFound;
        }

        const row = try store.media.get(ctx.db, ctx.arena, in.id) orelse return error.NotFound;
        const found = try store.records.get(ctx.db, ctx.arena, in.id) orelse {
            return error.NotFound;
        };
        const type_row = try content_types.find_raw(ctx, found.type_id) orelse {
            return error.NotFound;
        };

        if (type_row.def.kind != .media or !std.mem.eql(u8, type_row.def.owner, plugin)) {
            return error.NotFound;
        }

        return .{
            .key = row.storage_key,
            .filename = row.filename,
            .mime_type = row.mime_type,
            .size = @intCast(row.size),
        };
    }
};

const too_large: sdk.operation.Failure = .{
    .name = "FileTooLarge",
    .status = 413,
    .message = "The file is larger than the plugin may make; its limit is raised with " ++
        "`.limits.file_mib`.",
};

/// The plugin making the call: its code's, or the one it runs as.
fn plugin_of(ctx: *const Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    const plugin = switch (ctx.caller) {
        .plugin => |caller| caller.name,
        else => ctx.plugin,
    };

    if (plugin.len == 0) {
        return error.Denied;
    }

    return plugin;
}

/// Where a plugin's part is kept while it is written: under the plugin's name, so no other
/// plugin reaches it.
fn part_key(ctx: *Ctx, plugin: []const u8, part: []const u8) Error![]const u8 {
    std.debug.assert(plugin.len > 0);

    if (!upload.valid_token(part) or part.len < part_name_len_min) {
        return error.Invalid;
    }

    const key = try std.mem.concat(ctx.arena, u8, &.{ part_prefix, plugin, "-", part });

    if (!files_module.valid_key(key)) {
        return error.Invalid;
    }

    return key;
}

/// The largest file `plugin` may make: an installed plugin's granted limit, a compiled-in
/// one's the site's own; never past what the site keeps.
fn file_bytes_max(ctx: *const Ctx, plugin: []const u8) Error!u64 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(files_module.bytes_max > 0);

    const sandboxed = ctx.sandboxed_plugins orelse return files_module.bytes_max;

    for (sandboxed.manifests()) |manifest| {
        if (!std.mem.eql(u8, manifest.name, plugin)) {
            continue;
        }

        const granted: []const []const u8 = if (sandboxed.holds(plugin, "limit.file_mib"))
            &.{"limit.file_mib"}
        else
            &.{};
        const effective = model.sandboxed_plugin.effective_limits(manifest.limits, granted);

        return @min(@as(u64, effective.file_mib) << 20, files_module.bytes_max);
    }

    return files_module.bytes_max;
}
