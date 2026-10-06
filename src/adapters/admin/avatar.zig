//! `/admin/avatar/<hash>`: a signed-in user's Gravatar, served from the admin's own address.
//! The first request sets a thread fetching it (`?d=blank`, so someone without one gets a
//! transparent picture and their initials show through) and answers not found; the thread
//! keeps it beside the media library's resized copies, and every request after is served
//! from there, the browser keeping it a day. Until then, and when Gravatar has nothing to
//! give, the answer is a clear pixel.
//! Where Gravatar cannot be reached (a project without network, the browser build) the
//! answer is not found and the initials stay.

const std = @import("std");
const builtin = @import("builtin");
const admin = @import("../admin.zig");
const files_module = @import("../../lib/files.zig");

pub const hash_len: u32 = 32;

/// A one-pixel transparent PNG.
const clear_pixel = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
    0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
    0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78,
    0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};
const picture_size: u32 = 80;
const picture_bytes_max: u32 = 256 << 10;

/// The address the chrome's avatar loads: the MD5 of the trimmed, lowercased email.
pub fn address_of(arena: std.mem.Allocator, email: []const u8) ![]const u8 {
    std.debug.assert(email.len <= 512);

    if (email.len == 0) {
        return "";
    }

    var hash: [hash_len]u8 = undefined;

    hash_of(email, &hash);

    return std.fmt.allocPrint(arena, "/admin/avatar/{s}", .{&hash});
}

fn hash_of(email: []const u8, out: *[hash_len]u8) void {
    std.debug.assert(email.len > 0);

    var md5 = std.crypto.hash.Md5.init(.{});
    const trimmed = std.mem.trim(u8, email, " \t\r\n");

    for (trimmed) |char| {
        md5.update(&.{std.ascii.toLower(char)});
    }

    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;

    md5.final(&digest);
    out.* = std.fmt.bytesToHex(digest, .lower);

    std.debug.assert(valid_hash(out));
}

fn valid_hash(hash: []const u8) bool {
    std.debug.assert(hash_len == std.crypto.hash.Md5.digest_length * 2);

    if (hash.len != hash_len) {
        return false;
    }

    for (hash) |char| {
        if (!std.ascii.isDigit(char) and (char < 'a' or char > 'f')) {
            return false;
        }
    }

    return true;
}

pub fn show(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const hash = request.param("hash") orelse "";
    const files = session.project.files orelse return response.text(.not_found, "Not Found");

    if (!valid_hash(hash)) {
        return response.text(.not_found, "Not Found");
    }

    const key = try std.fmt.allocPrint(session.arena, "avatars/{s}.png", .{hash});
    const limit = picture_bytes_max;
    const kept = files.read(session.arena, .cache, key, limit) catch |err| switch (err) {
        error.NotFound => try fetched(&session, files, hash, key),
        else => return response.text(.not_found, "Not Found"),
    };

    // Nothing yet (being fetched), or nothing to have: a clear pixel, so the initials show
    // and no page reports a missing picture. Fetched, it is asked for again.
    if (kept.len == 0) {
        try response.set_header("Cache-Control", "no-store");
        return response.set_body(.ok, "image/png", &clear_pixel);
    }

    try response.set_header("Cache-Control", "private, max-age=86400");
    try response.set_body(.ok, "image/png", kept);
}

/// Asks Gravatar on a thread of its own, so no request waits on it: this one answers a
/// clear pixel (the initials show), a later one finds the picture kept.
fn fetched(
    session: *admin.Session,
    files: files_module.Files,
    hash: []const u8,
    key: []const u8,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(valid_hash(hash));
    std.debug.assert(key.len > hash.len);

    if (builtin.os.tag == .wasi) {
        return "";
    }

    const job = try std.heap.page_allocator.create(Job);

    job.* = .{ .files = files, .io = session.project.io, .hash = hash[0..hash_len].* };

    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
        std.log.warn("avatar: could not ask Gravatar: {t}", .{err});
        std.heap.page_allocator.destroy(job);
        return "";
    };

    thread.detach();

    return "";
}

const Job = struct {
    files: files_module.Files,
    io: std.Io,
    hash: [hash_len]u8,

    fn run(job: *Job) void {
        defer std.heap.page_allocator.destroy(job);

        std.debug.assert(valid_hash(&job.hash));

        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();

        const arena = arena_state.allocator();
        // An empty copy is a picture Gravatar could not give: asked once, not again.
        const picture = download(arena, job.io, &job.hash) catch |err| blk: {
            std.log.info("avatar: Gravatar did not answer: {t}", .{err});
            break :blk "";
        };
        var key_buffer: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buffer, "avatars/{s}.png", .{&job.hash}) catch
            unreachable;

        job.files.write(.cache, key, picture) catch |err| {
            std.log.warn("avatar: could not keep {s}: {t}", .{ key, err });
        };
    }
};

fn download(arena: std.mem.Allocator, io: std.Io, hash: []const u8) ![]const u8 {
    std.debug.assert(valid_hash(hash));
    std.debug.assert(picture_size > 0);

    const url = try std.fmt.allocPrint(
        arena,
        "https://gravatar.com/avatar/{s}?d=blank&s={d}",
        .{ hash, picture_size },
    );
    var body: std.Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .keep_alive = false,
        .response_writer = &body.writer,
    });

    if (result.status != .ok or body.written().len > picture_bytes_max) {
        return error.NoPicture;
    }

    return body.written();
}

test "address_of: Gravatar's hash of the trimmed, lowercased email" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "/admin/avatar/55502f40dc8b7c769880b10874abc9d0",
        try address_of(arena, " Test@Example.com "),
    );
    try std.testing.expectEqualStrings("", try address_of(arena, ""));
    try std.testing.expect(!valid_hash("../../etc/passwd"));
}
