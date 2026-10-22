//! `/admin/preview/...`: a record's page as it will read once published, and the site around
//! it, for whoever may edit it. Rendered on request and never written to the built site, which
//! holds live documents only.
//!
//! `GET :id` (`new?type=` for a record not saved yet) is the tab, for the signed-in editor: a
//! sandboxed frame on the record's page, and the editor's form, left in the tab's session
//! storage, posted into it, so a reload draws it again without asking to resend anything.
//! The frame's addresses are `/admin/preview/<pass>/site/<path>`: the pass (a signed, short
//! pass for this user and record) stands in for the session, which never reaches the frame,
//! and every link the page draws starts there, so browsing stays in the preview. The page is
//! the site's own markup and scripts, served with the site's sandbox policy: an opaque origin
//! that the session never reaches.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const record_operations = @import("../../operations/record.zig");
const identity_module = @import("../rest/identity.zig");
const shell = @import("../apps/shell.zig");
const page_module = @import("preview/page.zig");
const Project = @import("../../server/project.zig").Project;

const Session = admin.Session;
const Response = admin.Response;

const back = "/admin/content";
const prefix = "/admin/preview/";
const site_segment = "/site";
const expired = "This preview has expired. Open it again from the editor.";

/// Where a record not saved yet is previewed; its type follows as `?type=`.
pub const new_path = "/admin/preview/new";

pub const routes_count: u32 = 3;

/// The tab's script: posts the form the editor left into the frame.
const holder = @embedFile("preview/holder.js");

pub const page_for = page_module.page_for;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len < router.routes.len - routes_count);

    const before = router.routes_len;

    router.get("/admin/preview/:id", &tab);
    router.get("/admin/preview/:pass/site/*", &site);
    router.post("/admin/preview/:pass/site/*", &site);

    std.debug.assert(router.routes_len == before + routes_count);
}

/// The preview's tab: the record's page in a sandboxed frame, drawn from the form the editor
/// left in the tab's session storage, else from what is saved.
pub fn tab(request: *admin.Request, response: *Response, ctx: *admin.Context) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", back) orelse return;
    const user = session.ctx.caller.user_id() orelse {
        return admin.fail(&session, error.Forbidden, back);
    };
    const asked = admin.query_param(&session, "path");
    const kept = if (asked) |at| if (plain_path(at)) at else null else null;
    const path = kept orelse try own_path(&session, id) orelse {
        return response.text(.not_found, try session.translated("No page shows this record.", .{}));
    };
    const project = session.project;
    const pass = identity_module.preview_pass(project, session.arena, id, user) catch {
        return response.text(.bad_request, try session.translated("No such record.", .{}));
    };
    var out: std.Io.Writer.Allocating = .init(session.arena);

    out.writer.print(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
            "<title>Preview</title><style>html,body{{margin:0;height:100%}}" ++
            "iframe{{display:block;border:0;width:100%;height:100%}}</style></head><body>" ++
            "<iframe name=\"publr-preview\" title=\"Preview\" sandbox=\"{s}\" " ++
            "data-page=\"{s}{s}{s}{s}{s}\"></iframe><script>{s}</script></body></html>",
        .{ shell.sandbox, project.admin_path(), prefix, pass, site_segment, path, holder },
    ) catch return error.OutOfMemory;

    try response.set_header("Cache-Control", "no-store");

    return response.set_body(.ok, "text/html; charset=utf-8", out.written());
}

/// A page address the tab may put back in its frame: a path, without anything that would break
/// out of the attribute it is written into.
fn plain_path(path: []const u8) bool {
    std.debug.assert(path.len <= 64 << 10);
    std.debug.assert(prefix.len > 0);

    if (path.len == 0 or path.len > 1024 or path[0] != '/') {
        return false;
    }

    return std.mem.indexOfAny(u8, path, "\"'<>& \t\r\n\\") == null;
}

/// The record's own page inside the project: a saved one's by its edit copy, a new one's by
/// the type the editor names.
fn own_path(session: *Session, id: []const u8) admin.Error!?[]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;

    if (std.mem.eql(u8, id, "new")) {
        const handle = admin.query_param(session, "type") orelse return null;

        return page_module.own_path(session.project, arena, null, handle, null);
    }

    const got = registry.SDK.dispatch(&session.ctx, record_operations.Get, .{
        .id = id,
        .purpose = .edit,
    }) catch |err| {
        try admin.fail(session, err, back);

        return null;
    };
    const record = got.record;

    return page_module.own_path(session.project, arena, record.app, record.type, record.slug);
}

/// A page of the site in preview mode, for whoever holds the pass: the session never reaches
/// the sandboxed frame, so the pass is the only way in, and it opens nothing but this.
pub fn site(request: *admin.Request, response: *Response, ctx: *admin.Context) admin.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.path().len > 0);

    const project = Project.of(ctx);
    const arena = ctx.arena;
    const pass = request.param("pass") orelse return response.text(.not_found, "Not Found");
    const opened = identity_module.identify_preview(project, arena, pass) orelse {
        return response.text(.forbidden, expired);
    };
    const base = try std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{
        project.admin_path(),
        prefix,
        pass,
        site_segment,
    });
    const at = std.mem.indexOf(u8, request.path(), site_segment) orelse {
        return response.text(.not_found, "Not Found");
    };
    const rest = request.path()[at + site_segment.len ..];
    const posting = request.method() == .post;
    var form: ?admin.Form = if (posting) admin.Form.parse(arena, request.body) else null;
    const drawn = page_module.draw(.{
        .project = project,
        .arena = arena,
        .request = request,
        .caller = opened.caller,
        .record = opened.record,
        .path = if (rest.len == 0) "/" else rest,
        .base = base,
        .form = if (form) |*posted| posted else null,
    }) catch |err| {
        std.log.debug("preview {s}: {s}", .{ request.path(), @errorName(err) });

        return response.text(.internal_server_error, "The page could not be drawn.");
    };

    return switch (drawn) {
        .page => |html| sealed(response, html),
        .file => |address| response.redirect(.found, address),
        .missing => response.text(.not_found, "There is no such page in the preview."),
    };
}

fn sealed(response: *Response, html: []const u8) admin.Error!void {
    std.debug.assert(html.len > 0);
    std.debug.assert(shell.policy.len > 0);

    try response.set_header("Content-Security-Policy", shell.policy);
    try response.set_header("Cache-Control", "no-store");
    try response.set_header("X-Robots-Tag", "noindex");

    return response.set_body(.ok, "text/html; charset=utf-8", html);
}
