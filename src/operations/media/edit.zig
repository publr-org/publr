const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const record = @import("../record.zig");
const library = @import("library.zig");
const tags = @import("tags.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const ids_max: u32 = 200;
const focal_default: u8 = 50;

pub const TagRef = struct { id: []const u8, name: []const u8 };

pub const Detail = struct {
    media: library.Item,
    alt: []const u8,
    caption: []const u8,
    credit: []const u8,
    /// The subject, in percent across and down; resized crops keep it in view.
    focal_x: u8,
    focal_y: u8,
    folder: ?[]const u8,
    tags: []const TagRef,
};

pub const Get = struct {
    pub const name = "media.get";
    pub const description = "One file of the library: its facts and what people wrote";
    pub const details =
        \\The file as the library lists it, its alt text, caption, credit, focal point
        \\(percent across and down, 50/50 unless set), its folder and its tags. Signed-in
        \\callers only.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { id: []const u8 };
    pub const Out = Detail;
    pub const example: In = .{ .id = library.example_item.id };
    pub const example_out: Out = .{
        .media = library.example_item,
        .alt = "Fishing boats in the harbour",
        .caption = "",
        .credit = "Ada",
        .focal_x = 50,
        .focal_y = 40,
        .folder = null,
        .tags = &.{},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{ .id = "The file's record id" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .media = "The file as the library lists it",
        .alt = "What the image shows, for people who cannot see it",
        .caption = "A caption to show with it",
        .credit = "Who made it",
        .focal_x = "The subject's place across, in percent",
        .focal_y = "The subject's place down, in percent",
        .folder = "Its folder's id; none when unsorted",
        .tags = "Its tags",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const row = try library.row_of(ctx, in.id);
        const written = try library.written_of(ctx, row.record);
        const title = if (written.title.len > 0) written.title else row.filename;

        return .{
            .media = library.item_of(row, title),
            .alt = written.alt,
            .caption = written.caption,
            .credit = written.credit,
            .focal_x = percent_of(written.focal_x),
            .focal_y = percent_of(written.focal_y),
            .folder = written.media_folders,
            .tags = try tags.named(ctx, written.media_tags),
        };
    }
};

fn percent_of(value: ?i64) u8 {
    const known = value orelse return focal_default;

    std.debug.assert(focal_default <= 100);

    return @intCast(std.math.clamp(known, 0, 100));
}

pub const Update = struct {
    pub const name = "media.update";
    pub const description = "Change what is written about a file, where it is filed, who sees it";
    pub const details =
        \\Only the fields given change. `folder` moves the file (empty: unsorted); `tags`
        \\replaces its tags by name, making the ones that do not exist yet. Moving the focal
        \\point drops the resized copies made around the old one. `private` serves the file
        \\to signed-in users only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        title: ?[]const u8 = null,
        alt: ?[]const u8 = null,
        caption: ?[]const u8 = null,
        credit: ?[]const u8 = null,
        focal_x: ?u8 = null,
        focal_y: ?u8 = null,
        folder: ?[]const u8 = null,
        tags: ?[]const []const u8 = null,
        private: ?bool = null,
    };
    pub const Out = struct { id: []const u8 };
    pub const example: In = .{ .id = library.example_item.id, .alt = "Boats at dawn" };
    pub const example_out: Out = .{ .id = library.example_item.id };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The file's record id",
        .title = "Its title",
        .alt = "Alt text",
        .caption = "Caption",
        .credit = "Credit",
        .focal_x = "The subject's place across, 0 to 100",
        .focal_y = "The subject's place down, 0 to 100",
        .folder = "A folder's id; empty for none",
        .tags = "Every tag it should carry, by name",
        .private = "Whether only signed-in users may see it",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .id = "The file's record id" };

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
        });

        if (in.private) |private| {
            try store.media.set_private(ctx.db, row.record, private);
        }

        if (focal_moved) {
            (try library.files_of(ctx)).clear_copies(row.storage_key);
        }

        return .{ .id = row.record };
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

        try writer.endObject();
    }
};

pub const Delete = struct {
    pub const name = "media.delete";
    pub const description = "Remove files from the library for good, with their copies";
    pub const details =
        \\Each file's record, its row and its bytes go, with every resized copy. A file a
        \\record still points at is refused like any record that is referenced.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { ids: []const []const u8 };
    pub const Out = struct { deleted: u32 };
    pub const example: In = .{ .ids = &.{library.example_item.id} };
    pub const example_out: Out = .{ .deleted = 1 };
    pub const field_docs: sdk.operation.Docs(In) = .{ .ids = "The files' record ids, up to 200" };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .deleted = "How many files went" };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.ids.len == 0 or in.ids.len > ids_max) {
            return error.Invalid;
        }

        const files = try library.files_of(ctx);
        const keys = try ctx.arena.alloc([]const u8, in.ids.len);

        for (in.ids, keys) |id, *key| {
            const row = try library.row_of(ctx, id);

            _ = try registry.SDK.dispatch(ctx, record.Purge, .{ .id = row.record });
            key.* = row.storage_key;
        }

        // Last, once every record went: a refusal above leaves every file in place.
        for (keys) |key| {
            files.remove(.files, key);
            files.clear_copies(key);
        }

        return .{ .deleted = @intCast(keys.len) };
    }
};

pub const Move = struct {
    pub const name = "media.move";
    pub const description = "File several files in one folder, or in none";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { ids: []const []const u8, folder: []const u8 = "" };
    pub const Out = struct { moved: u32 };
    pub const example: In = .{ .ids = &.{library.example_item.id}, .folder = "" };
    pub const example_out: Out = .{ .moved = 1 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .ids = "The files' record ids, up to 200",
        .folder = "The folder's id; empty for none",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .moved = "How many files moved" };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.ids.len == 0 or in.ids.len > ids_max or in.folder.len > 64) {
            return error.Invalid;
        }

        for (in.ids) |id| {
            const row = try library.row_of(ctx, id);

            try library.save(ctx, row.record, Changes{ .folder = in.folder });
        }

        return .{ .moved = @intCast(in.ids.len) };
    }
};

pub const Tag = struct {
    pub const name = "media.tag";
    pub const description = "Add a tag to several files, or take it off";
    pub const details =
        \\The tag is named; adding one that does not exist yet makes it. Taking off a tag a
        \\file does not carry leaves the file as it is.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { ids: []const []const u8, tag: []const u8, remove: bool = false };
    pub const Out = struct { changed: u32 };
    pub const example: In = .{ .ids = &.{library.example_item.id}, .tag = "Harbour" };
    pub const example_out: Out = .{ .changed = 1 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .ids = "The files' record ids, up to 200",
        .tag = "The tag's name",
        .remove = "Take the tag off instead",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .changed = "How many files changed" };

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
                try library.save(ctx, row.record, Changes{ .tag_ids = next });
                changed += 1;
            }
        }

        return .{ .changed = changed };
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
