const operation = @import("../../operation.zig");
const library = @import("library.zig");

/// How many skipped files the answer names; the count covers the rest.
pub const skipped_listed_max: u32 = 50;

pub const Skipped = struct {
    path: []const u8,
    reason: []const u8,
};

pub const Sync = struct {
    pub const name = "media.sync";
    pub const description = "Take in the files put into the media folder by hand";
    pub const details =
        \\Walks the media folder beside the database (never its hidden areas, nor the ones
        \\other media types keep their files in, named after them) for files the
        \\library does not have yet and adds each as a published `media` record marked
        \\unreviewed. A file whose path can serve as its key (lowercase letters, digits,
        \\`.-_`, up to four parts) stays where it is; any other is moved under a dated key.
        \\Its directories name its folder: `Photos/Trips/a.jpg` is filed in Photos › Trips,
        \\made when missing; a top directory of four digits is the library's own layout and
        \\names none. Files of a type the library does not take, empty ones and ones whose
        \\bytes are not what their extension says are skipped with the reason. Every file
        \\of the library whose bytes are gone is marked missing, and one found again is
        \\not. With `check`, nothing is written: the answer says what a sync would do.
        \\Only a server keeps such a folder; in the browser it is `Unavailable`.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        check: bool = false,
    };
    pub const Out = struct {
        new: u32,
        added: u32,
        missing: u32,
        skipped: []const Skipped,
        skipped_count: u32,
        more: bool,
    };
    pub const example: In = .{
        .check = true,
    };
    pub const example_out: Out = .{
        .new = 0,
        .added = 0,
        .missing = 0,
        .skipped = &.{},
        .skipped_count = 0,
        .more = false,
    };
    pub const field_docs: operation.Docs(In) = .{
        .check = "Only report what a sync would do",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .new = "Files in the folder the library does not have",
        .added = "How many of them this call added",
        .missing = "Files of the library whose bytes are gone from the folder",
        .skipped = "Files left out and why, the first fifty",
        .skipped_count = "How many files were left out",
        .more = "The folder holds more files than one sync looks at; run it again",
    };
};
