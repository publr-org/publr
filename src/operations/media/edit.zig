const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/media/edit.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const record = @import("../record.zig");
const library = @import("library.zig");
const media_base = @import("../../sdk/media_base.zig");
const trash = @import("../trash.zig");
const tags = @import("tags.zig");
const site_dimensions = @import("../dimensions.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const ids_max = public.ids_max;
const focal_default: u8 = 50;

pub const TagRef = public.TagRef;

pub const Translation = public.Translation;

pub const translations_max = public.translations_max;

pub const Detail = public.Detail;

pub const Get = struct {
    pub const shape = public.Get;
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

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const row = try library.row_of(ctx, in.id);

        if (row.private and library.public_only(granted)) {
            return error.NotFound;
        }

        const written = try library.written_of(ctx, row.record);
        const translated = try translations_of(ctx, row.record);
        const title = if (written.title.len > 0) written.title else row.filename;

        return .{
            .media = library.item_of(row, title, try media_base.url(ctx, row.storage_key)),
            .alt = written.alt,
            .caption = written.caption,
            .credit = written.credit,
            .focal_x = percent_of(written.focal_x),
            .focal_y = percent_of(written.focal_y),
            .folder = written.media_folders,
            .tags = try tags.named(ctx, written.media_tags),
            .translations = translated,
        };
    }
};

/// The file's words in each of the site's other languages, as the record holds them.
fn translations_of(ctx: *Ctx, id: []const u8) Error![]const Translation {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const others = try site_dimensions.others(ctx);

    if (others.len == 0) {
        return &.{};
    }

    const got = try registry.SDK.dispatch(ctx, record.Get, .{
        .id = id,
    });
    const Value = std.json.Value;
    const document = std.json.parseFromSliceLeaky(Value, ctx.arena, got.document.text, .{}) catch {
        return error.Invalid;
    };
    const out = ctx.arena.alloc(Translation, others.len) catch return error.OutOfMemory;

    for (others, out) |value, *translation| {
        translation.* = .{
            .code = value.code,
            .title = try text_in(ctx, document, "title", value.code),
            .alt = try text_in(ctx, document, "alt", value.code),
            .caption = try text_in(ctx, document, "caption", value.code),
        };
    }

    return out;
}

fn text_in(
    ctx: *Ctx,
    document: std.json.Value,
    name: []const u8,
    code: []const u8,
) Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(code.len > 0);

    const key = try site_dimensions.key_in(ctx, name, code);
    const value = if (document == .object) document.object.get(key) else null;

    return if (value != null and value.? == .string) value.?.string else "";
}

fn percent_of(value: ?i64) u8 {
    const known = value orelse return focal_default;

    std.debug.assert(focal_default <= 100);

    return @intCast(std.math.clamp(known, 0, 100));
}

pub const Update = struct {
    pub const shape = public.Update;
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

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const row = try library.row_of(ctx, in.id);
        const focal_moved = in.focal_x != null or in.focal_y != null;

        if ((in.focal_x orelse 0) > 100 or (in.focal_y orelse 0) > 100) {
            return error.Invalid;
        }

        const tag_ids: ?[]const []const u8 = if (in.tags) |names|
            try tags.ensure(ctx, names)
        else
            null;

        try library.save(ctx, row.record, Changes{
            .title = in.title,
            .alt = in.alt,
            .caption = in.caption,
            .credit = in.credit,
            .focal_x = in.focal_x,
            .focal_y = in.focal_y,
            .folder = in.folder,
            .tag_ids = tag_ids,
            .translations = in.translations,
        });

        if (in.private) |private| {
            if (!private) {
                try library.may_be_public(ctx, row.record);
            }

            try store.media.set_private(ctx.db, row.record, private);
        }

        if (focal_moved) {
            (try library.files_of(ctx)).clear_copies(row.storage_key);
        }

        return .{
            .id = row.record,
        };
    }
};

/// The fields a change writes, as a document: absent fields are left out, an empty folder
/// is written as null, which leaves the file unsorted.
pub const Changes = struct {
    title: ?[]const u8 = null,
    alt: ?[]const u8 = null,
    caption: ?[]const u8 = null,
    credit: ?[]const u8 = null,
    focal_x: ?u8 = null,
    focal_y: ?u8 = null,
    folder: ?[]const u8 = null,
    tag_ids: ?[]const []const u8 = null,
    translations: []const Translation = &.{},

    pub fn jsonStringify(changes: Changes, writer: anytype) !void {
        std.debug.assert(changes.focal_x == null or changes.focal_x.? <= 100);

        try writer.beginObject();

        inline for (.{ "title", "alt", "caption", "credit", "focal_x", "focal_y" }) |field| {
            if (@field(changes, field)) |value| {
                try writer.objectField(field);
                try writer.write(value);
            }
        }

        if (changes.folder) |folder| {
            try writer.objectField(model.media.folders_handle);
            try writer.write(if (folder.len == 0) null else folder);
        }

        if (changes.tag_ids) |ids| {
            try writer.objectField(model.media.tags_handle);
            try writer.write(ids);
        }

        for (changes.translations) |translation| {
            try write_translation(writer, translation);
        }

        try writer.endObject();
    }
};

/// `title@pl`, `alt@pl`, `caption@pl`: an empty one written as null, cleared, so the
/// file reads the main language's there again.
fn write_translation(writer: anytype, translation: Translation) !void {
    std.debug.assert(translation.code.len > 0);

    if (!model.dimension.valid_code(translation.code)) {
        return error.WriteFailed;
    }

    var buffer: [64]u8 = undefined;

    inline for (.{ "title", "alt", "caption" }) |field| {
        const key = std.fmt.bufPrint(&buffer, field ++ "@{s}", .{translation.code}) catch {
            return error.WriteFailed;
        };
        const value = @field(translation, field);

        try writer.objectField(key);

        if (value.len == 0) {
            try writer.write(null);
        } else {
            try writer.write(value);
        }
    }
}

pub const Delete = struct {
    pub const shape = public.Delete;
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

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.ids.len == 0 or in.ids.len > ids_max) {
            return error.Invalid;
        }

        _ = try library.files_of(ctx);

        const kept = ctx.kept;
        defer ctx.kept = kept;

        var keys: [ids_max][]const u8 = undefined;

        // Each record into the trash with its file named, its purge part of a removal that can
        // be undone; the files move only once every record has gone, so a refusal (a file in
        // use) leaves every file where it was.
        for (in.ids, 0..) |id, index| {
            const row = try library.row_of(ctx, id);

            keys[index] = row.storage_key;

            const key = std.fmt.allocPrint(ctx.arena, "[\"{s}\"]", .{row.record}) catch {
                return error.OutOfMemory;
            };

            _ = try trash.keep(ctx, .{
                .kind = "media",
                .key = row.record,
                .label = std.fmt.allocPrint(ctx.arena, "File {s}", .{row.filename}) catch {
                    return error.OutOfMemory;
                },
                .roots = &.{
                    .{
                        .table = "records",
                        .column = "id",
                        .keys = key,
                    },
                    .{
                        .table = "record_search",
                        .column = "record",
                        .keys = key,
                    },
                    .{
                        .table = "snapshots",
                        .column = "record",
                        .keys = key,
                    },
                },
                .files = &.{row.storage_key},
            });
            ctx.kept = true;
            _ = try registry.SDK.dispatch(ctx, record.Purge, .{
                .id = row.record,
            });
            ctx.kept = kept;
        }

        for (keys[0..in.ids.len]) |key| {
            try trash.set_aside(ctx, key);
        }

        return .{
            .deleted = @intCast(in.ids.len),
        };
    }
};

pub const Move = struct {
    pub const shape = public.Move;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.ids.len == 0 or in.ids.len > ids_max or in.folder.len > 64) {
            return error.Invalid;
        }

        for (in.ids) |id| {
            const row = try library.row_of(ctx, id);

            try library.save(ctx, row.record, Changes{
                .folder = in.folder,
            });
        }

        return .{
            .moved = @intCast(in.ids.len),
        };
    }
};

pub const Tag = struct {
    pub const shape = public.Tag;
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

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.ids.len == 0 or in.ids.len > ids_max) {
            return error.Invalid;
        }

        const tag_id = (try tags.ensure(ctx, &.{in.tag}))[0];
        var changed: u32 = 0;

        for (in.ids) |id| {
            const row = try library.row_of(ctx, id);
            const written = try library.written_of(ctx, row.record);
            const next = try tags.toggled(ctx.arena, written.media_tags, tag_id, in.remove);

            if (next.len != written.media_tags.len) {
                try library.save(ctx, row.record, Changes{
                    .tag_ids = next,
                });
                changed += 1;
            }
        }

        return .{
            .changed = changed,
        };
    }
};

pub const operations = [_]type{ Get, Update, Delete, Move, Tag };

test "Changes: only what is given, an empty folder as null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const text = try std.json.Stringify.valueAlloc(arena, Changes{
        .alt = "Boats",
        .focal_x = 30,
        .folder = "",
        .tag_ids = &.{"t1"},
    }, .{});

    try std.testing.expectEqualStrings(
        "{\"alt\":\"Boats\",\"focal_x\":30,\"media_folders\":null,\"media_tags\":[\"t1\"]}",
        text,
    );
}

test "percent_of: unset is the middle, out of range is held to 0..100" {
    try std.testing.expectEqual(@as(u8, 50), percent_of(null));
    try std.testing.expectEqual(@as(u8, 100), percent_of(140));
    try std.testing.expectEqual(@as(u8, 0), percent_of(-3));
}
