const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const files_module = @import("../../lib/files.zig");
const http = @import("../http.zig");
const library = @import("library.zig");
const upload = @import("upload.zig");
const registry = @import("../../server/registry.zig");
const term = @import("../term.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const media = model.media;

pub const url_len_max: u32 = 2048;
/// Addresses one `import_many` takes: the server answers one request at a time, and a
/// batch holds it for every download in it.
pub const many_max: u32 = 20;

pub const operations = [_]type{ Import, ImportMany };

pub const Import = struct {
    pub const name = "media.import";
    pub const description = "Add a file from the web to the media library";
    pub const details =
        \\Downloads `url` (https or http, on a public address: never this machine or its
        \\network) and adds it as an upload is: its bytes must be what its extension says,
        \\up to 32 MiB, named after the address's last part unless `filename` says. How a
        \\site's own images come over when building something like it.
    ;
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .url = "The file's address",
        .filename = "The name it is kept under, with its extension; the address's own " ++
            "when left out",
        .folder = "The folder to file it in: its id, or its name (made when there is none " ++
            "of that name)",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.url.len == 0 or in.url.len > url_len_max) {
            return error.Invalid;
        }

        const filename = in.filename orelse name_of(in.url);

        if (!media.valid_filename(filename)) {
            return ctx.fail(unnamed);
        }

        const allocator = library.file_allocator;
        const downloaded = try http.download(ctx, allocator, in.url, files_module.bytes_max);
        defer allocator.free(downloaded.buffer);

        if (downloaded.status != 200) {
            return ctx.fail(not_a_file);
        }

        const folder = try folder_of(ctx, in.folder);

        const files = try library.files_of(ctx);

        return upload.add(ctx, files, media.type_def, filename, downloaded.bytes, folder);
    }
};

pub const ImportMany = struct {
    pub const name = "media.import_many";
    pub const description = "Add several files from the web to the media library at once";
    pub const details =
        \\Each of `urls` (up to 20) as `media import` takes one, in one call: what a site's
        \\images need instead of a call each. A file that cannot be added is listed in
        \\`failed` with why; the rest are added all the same.
    ;
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .urls = "The files' addresses, up to 20",
        .folder = "The folder to file them in: its id, or its name (made when there is " ++
            "none of that name)",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .added = "The files added, in the order asked",
        .failed = "Each address that could not be added, and why",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.urls.len == 0 or in.urls.len > many_max) {
            return error.Invalid;
        }

        var added: std.ArrayList(library.Item) = .empty;
        var failed: std.ArrayList(Failed) = .empty;
        const folder = try folder_of(ctx, in.folder);

        for (in.urls) |url| {
            // Each through the core: a savepoint, so one that fails undoes only itself.
            const item = registry.SDK.dispatch(ctx, Import, .{
                .url = url,
                .folder = folder,
            }) catch |err| {
                const why = if (ctx.failure) |failure| failure.message else reason_of(err);

                ctx.failure = null;
                failed.append(ctx.arena, .{
                    .url = url,
                    .why = why,
                }) catch return error.OutOfMemory;
                continue;
            };

            added.append(ctx.arena, item) catch return error.OutOfMemory;
        }

        return .{
            .added = added.items,
            .failed = failed.items,
        };
    }
};

/// A folder given by id, or by name: the media folder of that name, made when there is
/// none. People and agents name folders; ids are the library's.
pub fn folder_of(ctx: *Ctx, given: ?[]const u8) Error!?[]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    const wanted = std.mem.trim(u8, given orelse return null, " ");

    if (wanted.len == 0) {
        return null;
    }

    if (registry.SDK.dispatch(ctx, term.Get, .{
        .id = wanted,
    })) |found| {
        if (std.mem.eql(u8, found.term.type, "media_folders")) {
            return wanted;
        }
    } else |_| {
        ctx.failure = null;
    }

    const listed = try registry.SDK.dispatch(ctx, term.List, .{
        .taxonomy = "media_folders",
        .limit = 200,
    });

    for (listed.terms) |folder| {
        if (std.ascii.eqlIgnoreCase(folder.title, wanted)) {
            return folder.id;
        }
    }

    const document = std.json.Stringify.valueAlloc(ctx.arena, .{
        .name = wanted,
    }, .{}) catch return error.OutOfMemory;
    const made = try registry.SDK.dispatch(ctx, term.Create, .{
        .taxonomy = "media_folders",
        .document = document,
        .status = "published",
    });

    std.debug.assert(made.id.len > 0);

    return made.id;
}

/// Why a file was not added, in words, when the failure gave none.
fn reason_of(err: anyerror) []const u8 {
    std.debug.assert(@errorName(err).len > 0);

    return switch (err) {
        error.Invalid => "Not accepted: the address is not a file the library keeps",
        error.TooBig => "Too large: files are kept up to 32 MiB",
        error.NotFound => "Not found",
        else => @errorName(err),
    };
}

const unnamed: sdk.operation.Failure = .{
    .name = "Unnamed",
    .status = 422,
    .message = "The address names no file of a kind the library keeps: give `filename`",
};

const not_a_file: sdk.operation.Failure = .{
    .name = "NotAFile",
    .status = 502,
    .message = "The address did not answer with a file",
};

/// The address's last part, without its query: `https://a.eu/img/logo.png?v=2` is
/// `logo.png`.
pub fn name_of(url: []const u8) []const u8 {
    std.debug.assert(url.len <= url_len_max);

    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";

    return path[slash + 1 ..];
}

test "a file is named after its address's last part" {
    try std.testing.expectEqualStrings("logo.png", name_of("https://a.eu/img/logo.png?v=2"));
    try std.testing.expectEqualStrings("", name_of("https://a.eu/"));
    try std.testing.expectEqualStrings("b.jpg", name_of("https://a.eu/b.jpg#top"));
}
