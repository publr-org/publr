//! A media field as the record form draws it: the files the document points at, looked
//! up once in the library so each can show its preview, and what the field's rules let
//! people add.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const media = @import("../../../operations/media.zig");
const explorer = @import("../media/explorer.zig");

const Error = admin.Error;
const Session = admin.Session;
const Def = model.field.Def;
const Value = std.json.Value;

pub const File = admin.views.RecordFields.FilesItem;

/// How many files one record's form looks up; more are shown as missing.
pub const files_max: u32 = 200;

/// The file chooser's filter for each family it can name; a family missing here makes the
/// chooser offer every file.
const accepted = [_]struct {
    family: []const u8,
    accept: []const u8,
}{
    .{
        .family = "image",
        .accept = "image/*",
    },
    .{
        .family = "video",
        .accept = "video/*",
    },
    .{
        .family = "audio",
        .accept = "audio/*",
    },
    .{
        .family = "pdf",
        .accept = "application/pdf",
    },
};

/// The files the document's top-level media fields point at, as tiles keyed by id.
/// The files the document's media fields point at, as tiles keyed by id: top-level ones and
/// those inside a group or a repeater's items.
pub fn files_of(session: *Session, defs: []const Def, document: ?Value) Error![]const File {
    std.debug.assert(defs.len <= model.field.fields_max);
    std.debug.assert(session.signed_in());

    const object = document orelse return &.{};

    if (object != .object) {
        return &.{};
    }

    var found: std.ArrayList(File) = .empty;

    try collect(session, defs, object, &found);

    for (defs) |def| {
        const value = object.object.get(def.name) orelse continue;

        if (model.field.is_group(def.kind) and value == .object) {
            try collect(session, def.fields, value, &found);
        } else if (model.field.is_repeater(def.kind) and value == .array) {
            for (value.array.items) |item| {
                if (item == .object) {
                    try collect(session, def.fields, item, &found);
                }
            }
        }
    }

    return found.items;
}

/// Each media field's files in one object, looked up and added to `found`.
fn collect(
    session: *Session,
    defs: []const Def,
    object: Value,
    found: *std.ArrayList(File),
) Error!void {
    std.debug.assert(object == .object);
    std.debug.assert(found.items.len <= files_max);

    for (defs) |def| {
        const value = object.object.get(def.name) orelse continue;

        if (!is_media(def)) {
            continue;
        }

        const items: []const Value = if (value == .array) value.array.items else &.{value};

        for (items) |item| {
            if (item != .string or item.string.len == 0 or found.items.len == files_max) {
                continue;
            }

            const got = registry.SDK.dispatch(&session.ctx, media.Get, .{
                .id = item.string,
            }) catch continue;
            const file = try file_of(session.arena, got.media);

            found.append(session.arena, file) catch return error.OutOfMemory;
        }
    }
}

pub fn is_media(def: Def) bool {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(def.kind.len > 0);

    return model.kinds.lookup(registry.Kinds.all, def.kind).has.media;
}

/// One library file as a tile, before it has a place in a field.
pub fn file_of(arena: std.mem.Allocator, item: media.Item) Error!File {
    std.debug.assert(item.id.len > 0);
    std.debug.assert(item.filename.len > 0);

    const image = std.mem.eql(u8, item.family, "image");
    const icon = std.meta.stringToEnum(@FieldType(File, "icon"), explorer.icon_of(item.family));

    std.debug.assert(icon != null);

    return .{
        .id = item.id,
        .title = if (item.title.len > 0) item.title else item.filename,
        .thumb = if (image)
            try print(arena, "/media/{s}?w=480&h=480&fit=cover", .{item.key})
        else
            "",
        .image = image and !item.missing,
        .kind = try explorer.kind_of(arena, item.filename),
        .icon = icon.?,
        .facts = try explorer.facts_of(arena, item),
        .missing = item.missing,
        .slot = "",
        .place = "",
        .first = false,
        .last = false,
    };
}

/// The field's files in its own order, each with the form name it posts under; an id the
/// library no longer has is a missing tile, kept until someone removes it.
pub fn placed(
    arena: std.mem.Allocator,
    known: []const File,
    def: Def,
    name: []const u8,
    current: ?Value,
) Error![]const File {
    std.debug.assert(is_media(def));
    std.debug.assert(known.len <= files_max);

    const value = current orelse return &.{};
    const items: []const Value = if (value == .array) value.array.items else &.{value};
    var out: std.ArrayList(File) = .empty;

    for (items) |item| {
        if (item != .string or item.string.len == 0) {
            continue;
        }

        const index: u32 = @intCast(out.items.len);
        var file = find(known, item.string) orelse missing_of(item.string);

        file.slot = if (def.many) try print(arena, "{s}[{d}]", .{ name, index }) else name;
        file.place = try print(arena, "{d}", .{index});
        file.first = index == 0;
        out.append(arena, file) catch return error.OutOfMemory;
    }

    if (out.items.len > 0) {
        out.items[out.items.len - 1].last = true;
    }

    return out.items;
}

fn find(known: []const File, id: []const u8) ?File {
    std.debug.assert(id.len > 0);
    std.debug.assert(known.len <= files_max);

    for (known) |file| {
        if (std.mem.eql(u8, file.id, id)) {
            return file;
        }
    }

    return null;
}

fn missing_of(id: []const u8) File {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= model.validate.id_len_max);

    return .{
        .id = id,
        .title = id,
        .thumb = "",
        .image = false,
        .kind = "",
        .icon = .file,
        .facts = "",
        .missing = true,
        .slot = "",
        .place = "",
        .first = false,
        .last = false,
    };
}

/// What the file chooser offers: every family's filter, or anything when one has none.
pub fn accept_of(arena: std.mem.Allocator, families: []const []const u8) Error![]const u8 {
    std.debug.assert(families.len <= model.field.options.media_types_max);
    std.debug.assert(accepted.len > 0);

    var out: std.ArrayList(u8) = .empty;

    for (families) |family| {
        const accept = accept_for(family) orelse return "";

        if (out.items.len > 0) {
            out.append(arena, ',') catch return error.OutOfMemory;
        }

        out.appendSlice(arena, accept) catch return error.OutOfMemory;
    }

    return out.items;
}

fn accept_for(family: []const u8) ?[]const u8 {
    std.debug.assert(family.len > 0);
    std.debug.assert(accepted.len > 0);

    for (accepted) |entry| {
        if (std.mem.eql(u8, entry.family, family)) {
            return entry.accept;
        }
    }

    return null;
}

pub const Type = admin.views.RecordFields.TypesItem;

/// The families the field takes, each with the label people read it by.
pub fn types_of(arena: std.mem.Allocator, families: []const []const u8) Error![]const Type {
    std.debug.assert(families.len <= model.field.options.media_types_max);
    std.debug.assert(model.field.options.media_types.len > 0);

    const out = arena.alloc(Type, families.len) catch return error.OutOfMemory;

    for (families, out) |family, *entry| {
        entry.* = .{
            .id = family,
            .label = family,
        };

        for (model.field.options.media_types) |known| {
            if (std.mem.eql(u8, known.id, family)) {
                entry.label = known.label;
            }
        }
    }

    return out;
}

fn print(arena: std.mem.Allocator, comptime format: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.allocPrint(arena, format, args) catch return error.OutOfMemory;
}

test "the chooser's filter follows the families the field takes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("", try accept_of(arena, &.{}));
    try std.testing.expectEqualStrings("image/*", try accept_of(arena, &.{"image"}));
    try std.testing.expectEqualStrings(
        "image/*,application/pdf",
        try accept_of(arena, &.{ "image", "pdf" }),
    );
    try std.testing.expectEqualStrings("", try accept_of(arena, &.{ "image", "font" }));

    const types = try types_of(arena, &.{ "image", "pdf" });

    try std.testing.expectEqualStrings("Image", types[0].label);
    try std.testing.expectEqualStrings("PDF document", types[1].label);
}

test "a field's files keep its order, post under their slots, and a lost id stays" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const known = [_]File{missing_of("m2")};
    var list = std.json.Array.init(arena);

    try list.append(.{
        .string = "m1",
    });
    try list.append(.{
        .string = "m2",
    });

    const def: Def = .{
        .name = "gallery",
        .label = "Gallery",
        .kind = "media",
        .many = true,
    };
    const files = try placed(arena, &known, def, def.name, .{
        .array = list,
    });

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("gallery[0]", files[0].slot);
    try std.testing.expectEqualStrings("gallery[1]", files[1].slot);
    try std.testing.expect(files[0].first and !files[0].last);
    try std.testing.expect(files[1].last);
    try std.testing.expect(files[0].missing);

    const single: Def = .{
        .name = "cover",
        .label = "Cover",
        .kind = "media",
    };
    const one = try placed(arena, &.{}, single, "seo.image", .{
        .string = "m9",
    });

    try std.testing.expectEqualStrings("seo.image", one[0].slot);
    const none = try placed(arena, &.{}, single, "cover", null);

    try std.testing.expectEqual(@as(usize, 0), none.len);
}
