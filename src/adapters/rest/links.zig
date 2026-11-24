//! `/_links/<token>`: a signed link opened by a person who is not signed in (an unsubscribe,
//! a cart restored, a withdrawal). The token is checked (`operations/link.zig`); its intent
//! names the plugin's operation, which runs as that plugin, given `{ "subject" }`. It
//! answers `redirect` (a path on the site), shown as a redirect, `file` (the id of a file
//! the plugin made, `media.make`), served as a download, or `text`, shown as it is.
//! A link that is not good any more says so, and nothing runs.
const std = @import("std");
const http = @import("../../lib/http.zig");
const identity = @import("identity.zig");
const link = @import("../../operations/link.zig");
const registry = @import("../../server/registry.zig");
const Project = @import("../../server/project.zig").Project;

const Request = http.Request;
const Response = http.Response;
const Context = http.Context;

pub const prefix = "/_links/";
pub const routes_count: u32 = 1;

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len < router.routes.len - routes_count);
    std.debug.assert(prefix.len > 0);

    router.get(prefix ++ ":token", &open);
}

/// What a link's operation answers.
const Answer = struct {
    redirect: []const u8 = "",
    text: []const u8 = "",
    file: []const u8 = "",
};

fn open(request: *Request, response: *Response, ctx: *Context) anyerror!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);
    const token = request.param("token") orelse "";
    var sdk_ctx = identity.request_context(project, request, ctx.arena, .anonymous);
    const claims = try link.verified(&sdk_ctx, token) orelse {
        return response.text(.not_found, "This link does not work any more.");
    };
    const dot = std.mem.indexOfScalar(u8, claims.intent, '.') orelse {
        return response.text(.not_found, "This link does not work any more.");
    };

    // The intent is the plugin's own: its operation runs as the plugin.
    var running = identity.context(project, ctx.arena, .system);

    running.plugin = claims.intent[0..dot];
    running.address = sdk_ctx.address;

    const input = try std.json.Stringify.valueAlloc(ctx.arena, .{
        .subject = claims.subject,
    }, .{});
    const output = registry.SDK.call_json(&running, claims.intent, input) catch {
        return response.text(.not_found, "This link does not work any more.");
    };
    const answer = std.json.parseFromSliceLeaky(Answer, ctx.arena, output, .{
        .ignore_unknown_fields = true,
    }) catch Answer{};

    if (answer.file.len > 0) {
        return made_file(response, ctx, &running, answer.file);
    }

    const local = answer.redirect.len > 0 and answer.redirect[0] == '/' and
        (answer.redirect.len == 1 or answer.redirect[1] != '/');

    if (local) {
        return response.redirect(.see_other, answer.redirect);
    }

    return response.text(.ok, if (answer.text.len > 0) answer.text else "Done.");
}

/// A file the link's plugin made, whole, as a download named as it was made: one of
/// another plugin's, or none, is not found.
fn made_file(
    response: *Response,
    ctx: *Context,
    running: *@import("../../sdk.zig").Ctx,
    id: []const u8,
) anyerror!void {
    std.debug.assert(running.plugin.len > 0);
    std.debug.assert(id.len > 0);

    const project = Project.of(ctx);
    const files = project.files orelse return response.text(.service_unavailable, "No files");
    const made = registry.SDK.dispatch(running, media.made.Made, .{
        .id = id,
    }) catch {
        return response.text(.not_found, "This link does not work any more.");
    };
    const disposition = try std.fmt.allocPrint(ctx.arena, "attachment; filename=\"{s}\"", .{
        made.filename,
    });

    try response.set_header("Content-Disposition", disposition);
    try response.set_header("Cache-Control", "private, no-store");

    return media_adapter.original(response, ctx, files, made.key, made.mime_type);
}

const media = @import("../../operations/media.zig");
const media_adapter = @import("../media.zig");
