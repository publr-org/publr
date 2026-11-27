const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/media/import.zig");
const model = @import("../../model.zig");
const files_module = @import("../../lib/files.zig");
const http = @import("../http.zig");
const library = @import("library.zig");
const upload = @import("upload.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");
const jobs = @import("../job.zig");
const term = @import("../term.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const media = model.media;

pub const url_len_max = public.url_len_max;
pub const many_max = public.many_max;

pub const operations = [_]type{ Import, ImportMany };

pub const Import = struct {
    pub const shape = public.Import;
    pub const name = shape.name;
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

        if (in.url.len == 0 or in.url.len > url_len_max) {
            return error.Invalid;
        }

        const filename = in.filename orelse name_of(in.url);

        if (!media.valid_filename(filename)) {
            return ctx.fail(unnamed);
        }

        if (!public_url(in.url)) {
            return ctx.fail(http.not_public);
        }

        const pending = try upload.reserved(ctx, filename, try folder_of(ctx, in.folder));

        try jobs.enqueue(ctx, "media_import", Importing{
            .record = pending.id,
            .url = in.url,
        });

        return pending;
    }
};

/// An address the server may download from: https or http, on a public host.
fn public_url(url: []const u8) bool {
    std.debug.assert(url.len <= url_len_max);

    const uri = std.Uri.parse(url) catch return false;
    const host = switch (uri.host orelse return false) {
        .raw, .percent_encoded => |text| text,
    };
    const web = std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "http");

    return web and http.public_host(host);
}

pub const Importing = struct {
    /// The Pending file's record.
    record: []const u8,
    url: []const u8,
};

/// The `media_import` job: a Pending file's bytes downloaded and filled in; one that cannot
/// be is marked missing, and tried again later as a failed job is.
pub fn import_job(ctx: *Ctx, in: Importing) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(in.url.len > 0);

    const pending = try store.media.get(ctx.db, ctx.arena, in.record) orelse return;

    if (!pending.pending) {
        return;
    }

    filled(ctx, pending, in.url) catch |err| {
        try store.media.set_missing(ctx.db, in.record, true);

        return err;
    };
}

fn filled(ctx: *Ctx, pending: store.media.Row, url: []const u8) Error!void {
    std.debug.assert(pending.pending);

    const allocator = library.file_allocator;
    const downloaded = try http.download(ctx, allocator, url, files_module.bytes_max);
    defer allocator.free(downloaded.buffer);

    if (downloaded.status != 200) {
        return ctx.fail(not_a_file);
    }

    try upload.fill(ctx, pending, downloaded.bytes);
}

pub const ImportMany = struct {
    pub const shape = public.ImportMany;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const Failed = shape.Failed;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    const made = try term.published(ctx, .{
        .taxonomy = "media_folders",
        .document = .{
            .text = document,
        },
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
