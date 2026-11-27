//! Files a plugin makes (an invoice's PDF, a label, a feed, a CSV export): written in pieces,
//! so the plugin never holds the whole file, then kept as a file of one of its own media
//! types, a published record it references like any other. A file of a private media type
//! opens only to whoever may read the type (staff), or to whoever holds a link the plugin
//! signed (`/_links/<token>` answering `{ "file": <id> }`); it attaches to messages as any
//! file does. How large a file may be is the plugin's declared limit (`.limits.file_mib`,
//! granted with the plugin), never more than the site keeps.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/media/made.zig");
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

pub const part_bytes_max = public.part_bytes_max;
pub const part_name_len_min = public.part_name_len_min;
pub const part_name_len_max = public.part_name_len_max;
const part_prefix = "made-";

pub const WritePart = struct {
    pub const shape = public.WritePart;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.Make;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    pub const shape = public.Made;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
