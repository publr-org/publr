//! `POST /media/upload?filename=<name>[&folder=<id>]`: a file for the media library, its
//! bytes the request's body as they are. The body is taken as it arrives and written into
//! the library's uploads area a piece at a time, so a file of any size the library takes
//! never sits in memory; once it is in, `media.upload` checks it and adds it. Signed-in
//! callers from the admin only: the same origin and the session's CSRF token in
//! `X-Csrf-Token`. Answers 201 with the file as the library lists it.

const std = @import("std");
const http = @import("../../lib/http.zig");
const files_module = @import("../../lib/files.zig");
const ids = @import("../../lib/id.zig");
const model = @import("../../model.zig");
const Project = @import("../../server/project.zig").Project;
const identity = @import("../rest/identity.zig");
const registry = @import("../../server/registry.zig");
const media = @import("../../operations/media.zig");

const cookie_len_max: u32 = 256;
const token_len: u32 = 20;

/// One upload under way: what `finish` needs once the request's head is gone.
const Upload = struct {
    files: files_module.Files,
    project: *const Project,
    token: [token_len]u8,
    received: u64 = 0,
    filename_buffer: [model.media.filename_len_max]u8 = undefined,
    filename_len: u32,
    folder_buffer: [64]u8 = undefined,
    folder_len: u32,
    cookie_buffer: [cookie_len_max]u8 = undefined,
    cookie_len: u32,

    fn filename(state: *const Upload) []const u8 {
        std.debug.assert(state.filename_len > 0);

        return state.filename_buffer[0..state.filename_len];
    }
};

pub const stream: http.Router.Stream = .{
    .bytes_max = files_module.bytes_max,
    .open = &open,
    .write = &write,
    .finish = &finish,
    .abort = &abort,
};

fn open(request: *http.Request, response: *http.Response, ctx: *http.Context) anyerror!?*anyopaque {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .post);

    const project = Project.of(ctx);
    const files = project.files orelse {
        try response.json(.service_unavailable, .{ .@"error" = "Unavailable" });
        return null;
    };
    const who = identity.identify(request, ctx.arena, project);

    if (who.session == null) {
        try response.json(.unauthorized, .{ .@"error" = "Unauthorized" });
        return null;
    }

    if (!try identity.guard(request, response, project, &who)) {
        return null;
    }

    const filename = http.Form.query_param(ctx.arena, request.query(), "filename") orelse "";
    const folder = http.Form.query_param(ctx.arena, request.query(), "folder") orelse "";
    const cookie = request.header("cookie") orelse "";

    if (!model.media.valid_filename(filename) or folder.len > 64 or cookie.len > cookie_len_max) {
        try response.json(.unprocessable_content, .{ .@"error" = "Invalid" });
        return null;
    }

    const state = try std.heap.page_allocator.create(Upload);

    state.* = .{
        .files = files,
        .project = project,
        .token = undefined,
        .filename_len = @intCast(filename.len),
        .folder_len = @intCast(folder.len),
        .cookie_len = @intCast(cookie.len),
    };
    token_of(ctx, &state.token);
    @memcpy(state.filename_buffer[0..filename.len], filename);
    @memcpy(state.folder_buffer[0..folder.len], folder);
    @memcpy(state.cookie_buffer[0..cookie.len], cookie);

    return state;
}

/// Lowercase letters and digits, as an upload's token is.
fn token_of(ctx: *http.Context, out: *[token_len]u8) void {
    std.debug.assert(token_len <= ids.len);

    const project = Project.of(ctx);
    var random: [ids.len]u8 = undefined;

    @memcpy(out, ids.random(project.io, &random)[0..token_len]);

    std.debug.assert(media.upload.valid_token(out));
}

fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
    const state: *Upload = @ptrCast(@alignCast(context));

    std.debug.assert(bytes.len > 0);
    std.debug.assert(state.received + bytes.len <= files_module.bytes_max);

    state.received = try state.files.append(.incoming, &state.token, state.received, bytes);
}

fn finish(context: *anyopaque, response: *http.Response, ctx: *http.Context) anyerror!void {
    const state: *Upload = @ptrCast(@alignCast(context));
    defer std.heap.page_allocator.destroy(state);

    std.debug.assert(state.filename_len > 0);

    if (state.received == 0) {
        state.files.remove(.incoming, &state.token);
        return response.json(.unprocessable_content, .{ .@"error" = "Empty" });
    }

    const caller = caller_of(state, ctx.arena);
    var sdk_ctx = identity.context(state.project, ctx.arena, caller);
    const folder = state.folder_buffer[0..state.folder_len];
    const added = registry.SDK.dispatch(&sdk_ctx, media.Upload, .{
        .upload = &state.token,
        .filename = state.filename(),
        .folder = if (folder.len > 0) folder else null,
    }) catch |err| {
        state.files.remove(.incoming, &state.token);
        return refusal(response, &sdk_ctx, err);
    };

    try response.json(.created, added);
}

/// Who the upload is for, worked out again from the cookie its head carried.
fn caller_of(state: *const Upload, arena: std.mem.Allocator) @import("../../sdk.zig").Caller {
    std.debug.assert(state.cookie_len <= cookie_len_max);

    const head = std.fmt.allocPrint(
        arena,
        "POST {s} HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n",
        .{ "/media/upload", state.cookie_buffer[0..state.cookie_len] },
    ) catch return .anonymous;
    const parsed = http.parse(head) catch return .anonymous;
    const request: http.Request = .{ .inner = &parsed.complete, .body = "" };

    return identity.identify(&request, arena, state.project).caller;
}

fn refusal(
    response: *http.Response,
    ctx: *const @import("../../sdk.zig").Ctx,
    err: anyerror,
) !void {
    std.debug.assert(@intFromError(err) != 0);

    if (ctx.failure) |failure| {
        const status: http.Status = @enumFromInt(failure.status);

        return response.json(status, .{ .@"error" = failure.name, .message = failure.message });
    }

    const status: http.Status = switch (err) {
        error.Denied => .forbidden,
        error.NotFound => .not_found,
        error.Invalid => .unprocessable_content,
        error.Unavailable => .service_unavailable,
        else => .internal_server_error,
    };

    try response.json(status, .{ .@"error" = @errorName(err) });
}

fn abort(context: *anyopaque) void {
    const state: *Upload = @ptrCast(@alignCast(context));

    std.debug.assert(state.filename_len > 0);

    state.files.remove(.incoming, &state.token);
    std.heap.page_allocator.destroy(state);
}
