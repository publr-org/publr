const operation = @import("../../operation.zig");
const library = @import("library.zig");

pub const url_len_max: u32 = 2048;

/// Addresses one `import_many` takes.
pub const many_max: u32 = 20;

pub const Import = struct {
    pub const name = "media.import";
    pub const description = "Add a file from the web to the media library";
    pub const details =
        \\Adds the file at once, Pending: its id and address can be used straight away, and
        \\its bytes follow in the background, downloaded from `url` (https or http, on a
        \\public address: never this machine or its network) and checked as an upload is:
        \\what its extension says, up to 32 MiB. Named after the address's last part unless
        \\`filename` says. One that cannot be downloaded is marked missing. How a site's own
        \\images come over when building something like it.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        url: []const u8,
        filename: ?[]const u8 = null,
        folder: ?[]const u8 = null,
    };
    pub const Out = library.Item;
    pub const example: In = .{
        .url = "https://example.com/images/harbour.png",
    };
    pub const example_out: Out = library.example_item;
    pub const field_docs: operation.Docs(In) = .{
        .url = "The file's address",
        .filename = "The name it is kept under, with its extension; the address's own " ++
            "when left out",
        .folder = "The folder to file it in: its id, or its name (made when there is none " ++
            "of that name)",
    };
};

pub const ImportMany = struct {
    pub const name = "media.import_many";
    pub const description = "Add several files from the web to the media library at once";
    pub const details =
        \\Each of `urls` (up to 20) as `media import` takes one, in one call: what a site's
        \\images need instead of a call each, each added Pending, its bytes following in the
        \\background. An address that cannot be taken is listed in `failed` with why; the
        \\rest are added all the same.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        urls: []const []const u8,
        folder: ?[]const u8 = null,
    };
    pub const Out = struct {
        added: []const library.Item,
        failed: []const Failed,
    };
    pub const Failed = struct {
        url: []const u8,
        why: []const u8,
    };
    pub const example: In = .{
        .urls = &.{ "https://example.com/images/harbour.png", "https://example.com/logo.svg" },
    };
    pub const example_out: Out = .{
        .added = &.{library.example_item},
        .failed = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{
        .urls = "The files' addresses, up to 20",
        .folder = "The folder to file them in: its id, or its name (made when there is " ++
            "none of that name)",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .added = "The files added, in the order asked",
        .failed = "Each address that could not be added, and why",
    };
};
