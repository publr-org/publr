const operation = @import("../../operation.zig");
const library = @import("library.zig");
const std = @import("std");
const Extended = @import("../../extended.zig").Extended;
const Error = operation.Error;

pub const page_size_default: u32 = 25;

pub const Folder = struct {
    id: []const u8,
    name: []const u8,
    parent: ?[]const u8,
    depth: u32,
    /// The files in it and below it that the rest of the filter keeps.
    count: u32,
};

pub const Tag = struct {
    id: []const u8,
    name: []const u8,
    count: u32,
};

pub const Period = struct {
    year: u32,
    month: u32,
    count: u32,
};

pub const List = struct {
    pub const name = "media.list";
    pub const description = "A media type's files a filter keeps, with the explorer's counts";
    pub const details =
        \\The files of one media type: the library (`media`) unless `type` names another; one type's
        \\files never show among another's. Newest first, `limit` a page (25 by default). `folder`
        \\is a folder's id (its files and those of the folders below it), `unsorted` (files in no
        \\folder), `unreviewed` (files taken in from the media folder that no one has looked at), or
        \\empty for all. Every tag in `tags` must be on a file; `search` matches its name or title;
        \\`year` and `month` its upload date; `kind`, `size` and `visibility` the file itself;
        \\`families` keeps a media field's file families. Beside the page: the folder tree, each
        \\folder with the files it would show keeping the rest of the filter; the tags, each with
        \\what adding it would leave; the months files were uploaded in; and what All files,
        \\Unsorted and Unreviewed would hold. Folders and tags are the library's alone. Signed-in
        \\callers only.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        type: []const u8 = @import("../../model/media.zig").type_handle,
        folder: []const u8 = "",
        tags: []const []const u8 = &.{},
        search: []const u8 = "",
        year: ?u32 = null,
        month: ?u32 = null,
        kind: []const u8 = "",
        /// A media field's `types`, so a picker offers only what the field takes.
        families: []const []const u8 = &.{},
        size: []const u8 = "",
        visibility: []const u8 = "",
        limit: u32 = page_size_default,
        offset: u32 = 0,
    };
    pub const Out = struct {
        items: []const library.Item,
        /// How many files the whole filter keeps.
        total: u32,
        all: u32,
        unsorted: u32,
        unreviewed: u32,
        folders: []const Folder,
        tags: []const Tag,
        periods: []const Period,
        /// Fields plugins add to each file (`.register_columns` on `media`), by its id.
        extended: Extended = .{},

        /// A field of the hooking plugin's own on a file: `out.extend(item, "stock.uses", 3)`.
        pub fn extend(
            out: *const Out,
            item: library.Item,
            field: []const u8,
            value: anytype,
        ) Error!void {
            std.debug.assert(item.id.len > 0);

            return out.extended.put(item.id, field, value);
        }
    };
    pub const example: In = .{
        .folder = "unsorted",
        .limit = 25,
    };
    pub const example_out: Out = .{
        .items = &.{library.example_item},
        .total = 1,
        .all = 3,
        .unsorted = 1,
        .unreviewed = 0,
        .folders = &.{.{
            .id = "2a3b4c5d6e7f80910a1b2c3d",
            .name = "Photos",
            .parent = null,
            .depth = 0,
            .count = 0,
        }},
        .tags = &.{},
        .periods = &.{.{
            .year = 2026,
            .month = 10,
            .count = 3,
        }},
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "The media type, by handle; `media`, the library, by default",
        .folder = "A folder's id, `unsorted`, `unreviewed`, or empty for every file",
        .tags = "Tag ids; a file must carry each one",
        .search = "Part of a file's name or title",
        .year = "Uploaded in this year",
        .month = "With `year`: uploaded in this month, 1 to 12",
        .kind = "`image`, `video`, `audio`, `pdf` or `other`; empty for any",
        .families = "File families, as a media field's types name them; empty for any",
        .size = "`small` (under 1 MiB), `medium` (1 to 10 MiB) or `large`; empty for any",
        .visibility = "`public` or `private`; empty for both",
        .limit = "Page size, up to 200",
        .offset = "Files to skip",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .items = "The page of files",
        .total = "How many files the filter keeps",
        .all = "How many the filter keeps in any folder",
        .unsorted = "How many it keeps in no folder",
        .unreviewed = "How many it keeps that came from the media folder unreviewed",
        .folders = "Every folder in tree order, with its depth and count",
        .tags = "Every tag, with its count",
        .periods = "The months files were uploaded in, newest first, with counts",
        .extended = "Fields plugins add to each file, by its id",
    };
};
