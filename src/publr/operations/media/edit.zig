const operation = @import("../../operation.zig");
const library = @import("library.zig");

pub const ids_max: u32 = 200;

pub const TagRef = struct {
    id: []const u8,
    name: []const u8,
};

/// What is written about a file in one of the site's other languages: empty where it
/// reads the main language's.
pub const Translation = struct {
    code: []const u8,
    title: []const u8 = "",
    alt: []const u8 = "",
    caption: []const u8 = "",
};

pub const translations_max: u32 = 64;

pub const Detail = struct {
    media: library.Item,
    alt: []const u8,
    caption: []const u8,
    credit: []const u8,
    /// The title, alt text and caption in each of the site's other languages.
    translations: []const Translation = &.{},
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
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = Detail;
    pub const example: In = .{
        .id = library.example_item.id,
    };
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The file's record id",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .media = "The file as the library lists it",
        .alt = "What the image shows, for people who cannot see it",
        .caption = "A caption to show with it",
        .credit = "Who made it",
        .focal_x = "The subject's place across, in percent",
        .focal_y = "The subject's place down, in percent",
        .folder = "Its folder's id; none when unsorted",
        .tags = "Its tags",
        .translations = "The title, alt text and caption in each other language (`code`)",
    };
};

pub const Update = struct {
    pub const name = "media.update";
    pub const description = "Change what is written about a file, where it is filed, who sees it";
    pub const details =
        \\Only the fields given change. `folder` moves the file (empty: unsorted); `tags`
        \\replaces its tags by name, making the ones that do not exist yet. Moving the focal
        \\point drops the resized copies made around the old one. `private` serves the file
        \\to signed-in users only.
    ;
    pub const kind: operation.Kind = .write;
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
        /// The words in other languages; an empty one reads the main language's again.
        translations: []const Translation = &.{},
    };
    pub const Out = struct {
        id: []const u8,
    };
    pub const example: In = .{
        .id = library.example_item.id,
        .alt = "Boats at dawn",
    };
    pub const example_out: Out = .{
        .id = library.example_item.id,
    };
    pub const field_docs: operation.Docs(In) = .{
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
    pub const output_docs: operation.Docs(Out) = .{
        .id = "The file's record id",
    };
};

pub const Delete = struct {
    pub const name = "media.delete";
    pub const description = "Remove files from the library into the trash";
    pub const details =
        \\Each file leaves the library: its record and row, kept in the trash with the file
        \\itself, which `trash restore` brings back as it was. Resized copies go (they are made
        \\again). A file a record still points at is refused like any record that is
        \\referenced.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        ids: []const []const u8,
    };
    pub const Out = struct {
        deleted: u32,
    };
    pub const example: In = .{
        .ids = &.{library.example_item.id},
    };
    pub const example_out: Out = .{
        .deleted = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .ids = "The files' record ids, up to 200",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .deleted = "How many files went",
    };
};

pub const Move = struct {
    pub const name = "media.move";
    pub const description = "File several files in one folder, or in none";
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        ids: []const []const u8,
        folder: []const u8 = "",
    };
    pub const Out = struct {
        moved: u32,
    };
    pub const example: In = .{
        .ids = &.{library.example_item.id},
        .folder = "",
    };
    pub const example_out: Out = .{
        .moved = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .ids = "The files' record ids, up to 200",
        .folder = "The folder's id; empty for none",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .moved = "How many files moved",
    };
};

pub const Tag = struct {
    pub const name = "media.tag";
    pub const description = "Add a tag to several files, or take it off";
    pub const details =
        \\The tag is named; adding one that does not exist yet makes it. Taking off a tag a
        \\file does not carry leaves the file as it is.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        ids: []const []const u8,
        tag: []const u8,
        remove: bool = false,
    };
    pub const Out = struct {
        changed: u32,
    };
    pub const example: In = .{
        .ids = &.{library.example_item.id},
        .tag = "Harbour",
    };
    pub const example_out: Out = .{
        .changed = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .ids = "The files' record ids, up to 200",
        .tag = "The tag's name",
        .remove = "Take the tag off instead",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .changed = "How many files changed",
    };
};
