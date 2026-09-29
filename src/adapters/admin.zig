const std = @import("std");
const sdk = @import("../sdk.zig");
const auth = @import("../lib/auth.zig");
const identity_module = @import("rest/identity.zig");
const http = @import("../lib/http.zig");
const Project = @import("../server/project.zig").Project;
const registry = @import("../server/registry.zig");
const types = @import("../operations/content_type.zig");
const users = @import("../operations/user.zig");
pub const auth_pages = @import("admin/auth.zig");
const settings_pages = @import("admin/settings.zig");
const user_pages = @import("admin/users.zig");
const structure_pages = @import("admin/structure.zig");
const types_pages = @import("admin/types.zig");
const taxonomy_pages = @import("admin/taxonomies.zig");
const term_pages = @import("admin/terms.zig");
const field_pages = @import("admin/type_fields.zig");
const content_pages = @import("admin/content.zig");
const revision_pages = @import("admin/revisions.zig");

pub const Request = http.Request;
pub const Response = http.Response;
pub const Context = http.Context;
pub const Error = http.Error;
pub const Status = http.Status;
pub const Form = http.Form;

/// A POST that may change something: a signed-in session, a parseable form, from our own
/// page (same origin, valid CSRF token). `accept` answers null after responding otherwise.
pub const Post = struct { session: Session, form: Form };

pub fn accept(request: *Request, response: *Response, ctx: *Context, back: []const u8) Error!?Post {
    std.debug.assert(request.method() == .post);
    std.debug.assert(back.len > 0);

    const session = try require(request, response, ctx) orelse return null;
    const form = Form.parse(ctx.arena, request.body) orelse {
        try fail(&session, error.BadForm, back);

        return null;
    };

    if (!session.guard(&form)) {
        try fail(&session, error.RefusedCrossSite, back);

        return null;
    }

    return .{ .session = session, .form = form };
}

/// A route parameter that must be there; answers null after a not-found page otherwise.
pub fn param(session: *const Session, name: []const u8, back: []const u8) Error!?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(back.len > 0);

    return session.request.param(name) orelse {
        try fail(session, error.NotFound, back);

        return null;
    };
}

/// One query-string parameter, decoded; null when absent or empty.
pub fn query_param(session: *const Session, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(session.request.query().len <= 64 << 10);

    return Form.query_param(session.arena, session.request.query(), name);
}

pub const render = @import("../ui/render.zig");
pub const views = @import("views");

pub const form_pairs_max = Form.pairs_max;
pub const page_bytes_max: u32 = 4 << 20;
pub const routes_count: u32 = 126 + client_files.names.len;
const client_files = @import("../ui/client_files.zig");

const styles_css = @embedFile("styles_css");
const stores_js = @embedFile("admin_stores_js");

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len < 256 - routes_count);

    const before = router.routes_len;

    router.get("/admin", &auth_pages.home);
    register_assets(router);

    router.get("/admin/setup", &auth_pages.setup_page);
    router.post("/admin/setup", &auth_pages.setup);
    router.get("/admin/login", &auth_pages.login_page);
    router.post("/admin/login", &auth_pages.login);
    router.post("/admin/logout", &auth_pages.logout);
    router.get("/admin/settings", &settings_pages.show);
    router.get("/admin/settings/system", &settings_pages.system);
    router.get("/admin/settings/users", &user_pages.list);
    router.get("/admin/settings/users/new", &user_pages.new_page);
    router.post("/admin/settings/users/create", &user_pages.create);
    router.get("/admin/settings/users/:id", &user_pages.edit);
    router.post("/admin/settings/users/:id/update", &user_pages.update);
    router.post("/admin/settings/users/:id/password-link", &user_pages.password_link);
    router.post("/admin/settings/users/:id/delete", &user_pages.delete);
    @import("admin/plugins.zig").register(router);
    router.get("/admin/settings/:handle", &@import("admin/content/form.zig").settings_page);
    router.get("/admin/structure", &structure_pages.show);
    register_schemas(router);
    router.get("/admin/taxonomies", &taxonomy_pages.list);
    router.get("/admin/taxonomies/new", &taxonomy_pages.new_page);
    router.post("/admin/taxonomies/create", &taxonomy_pages.create);
    router.get("/admin/taxonomies/:handle", &term_pages.list);
    router.get("/admin/taxonomies/:handle/settings", &taxonomy_pages.settings_page);
    router.post("/admin/taxonomies/:handle/update", &taxonomy_pages.update);
    router.post("/admin/taxonomies/:handle/delete", &taxonomy_pages.delete);
    router.get("/admin/terms/new", &term_pages.new_page);
    router.get("/admin/terms/new/editor", &term_pages.new_editor);
    router.post("/admin/terms/create", &term_pages.create);
    router.get("/admin/terms/:id", &term_pages.edit);
    router.get("/admin/terms/:id/editor", &term_pages.editor_fragment);
    router.post("/admin/terms/:id/save", &term_pages.save);
    router.post("/admin/terms/:id/action", &term_pages.action);
    router.get("/admin/content", &content_pages.list);
    router.get("/admin/content/new", &content_pages.new_page);
    router.get("/admin/content/new/editor", &content_pages.new_editor);
    router.get("/admin/content/pick", &content_pages.pick);
    router.post("/admin/content/create", &content_pages.create);
    router.get("/admin/content/:id", &content_pages.edit);
    router.get("/admin/content/:id/editor", &content_pages.editor_fragment);
    router.post("/admin/content/:id/save", &content_pages.save);
    router.post("/admin/content/:id/action", &content_pages.action);
    router.post("/admin/views/create", &content_pages.view_pages.create);
    router.post("/admin/views/:id/save", &content_pages.view_pages.save);
    router.post("/admin/views/:id/rename", &content_pages.view_pages.rename);
    router.post("/admin/views/:id/delete", &content_pages.view_pages.delete);
    router.get("/admin/content/:id/revisions", &revision_pages.list);
    router.get("/admin/content/:id/revisions/:seq", &revision_pages.show);
    router.post("/admin/content/:id/restore", &revision_pages.restore);

    std.debug.assert(router.routes_len == before + routes_count);
}

fn register_schemas(router: *http.Router) void {
    std.debug.assert(router.routes_len < 200);
    register_definition(router, "/admin/types", types_pages);
    register_definition(router, "/admin/structure/taxonomies", taxonomy_pages.Structure);
    register_definition(router, "/admin/structure/settings", @import("admin/setting_types.zig"));
    register_definition(router, "/admin/components", @import("admin/components.zig"));
    router.get("/admin/custom-fields", &@import("admin/custom_fields.zig").list);
    router.get("/admin/custom-fields/new", &@import("admin/custom_fields.zig").new_page);
    router.post("/admin/custom-fields/create", &@import("admin/custom_fields.zig").create);
    router.post("/admin/custom-fields/:handle/delete", &@import("admin/custom_fields.zig").delete);
    router.post("/admin/custom-fields/:handle/update", &@import("admin/field_group.zig").save);
    register_fields(router, "/admin/custom-fields");
}

fn register_definition(router: *http.Router, comptime base: []const u8, comptime Pages: type) void {
    std.debug.assert(base.len > 0);
    router.get(base, &Pages.list);
    router.get(base ++ "/new", &Pages.new_page);
    router.post(base ++ "/create", &Pages.create);
    router.get(base ++ "/:handle/settings", &Pages.settings_page);
    router.post(base ++ "/:handle/update", &Pages.update);
    router.post(base ++ "/:handle/delete", &Pages.delete);
    register_fields(router, base);
}

fn register_fields(router: *http.Router, comptime base: []const u8) void {
    std.debug.assert(base.len > 0);
    const show = if (comptime std.mem.eql(u8, base, "/admin/custom-fields"))
        &@import("admin/field_group.zig").show
    else
        &field_pages.show;
    router.get(base ++ "/:handle", show);
    router.get(base ++ "/:handle/fields/new", &field_pages.new_field);
    router.post(base ++ "/:handle/fields/create", &field_pages.writes.create);
    router.get(base ++ "/:handle/fields/:name", &field_pages.edit);
    router.post(base ++ "/:handle/fields/:name/update", &field_pages.writes.update);
    router.post(base ++ "/:handle/fields/:name/delete", &field_pages.writes.delete);
    router.post(base ++ "/:handle/fields/:name/move", &field_pages.writes.move);
}

fn register_assets(router: *http.Router) void {
    std.debug.assert(router.routes_len < 256 - client_files.names.len - 2);
    router.get("/admin/styles.css", &styles);
    router.get("/admin/stores.js", &stores);

    inline for (client_files.names) |name| {
        router.get("/admin/" ++ name ++ ".js", &struct {
            fn serve(_: *Request, response: *Response, _: *Context) Error!void {
                try script(response, @embedFile(name));
            }
        }.serve);
    }
}

/// The admin stylesheet, compiled by the build from the classes the views use.
fn styles(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    try response.set_body(.ok, "text/css; charset=utf-8", styles_css);
    try response.set_header("Cache-Control", "no-cache");
}

/// The client half of the pages that keep state in the browser, and the runtime it
/// imports (`publr.js` pulls `publr-position.js` itself).
fn stores(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    try script(response, stores_js);
}

fn script(response: *Response, source: []const u8) Error!void {
    std.debug.assert(source.len > 0);
    std.debug.assert(response.body.len == 0);

    try response.set_body(.ok, "text/javascript; charset=utf-8", source);
    try response.set_header("Cache-Control", "no-cache");
}

/// One admin request: who is calling, where the answer goes, and a context to dispatch
/// operations with.
pub const Session = struct {
    request: *Request,
    response: *Response,
    arena: std.mem.Allocator,
    project: *Project,
    identity: identity_module.Identity,
    ctx: sdk.Ctx,
    csrf: [auth.csrf.token_len]u8 = undefined,

    pub fn open(request: *Request, response: *Response, ctx: *Context) Session {
        std.debug.assert(ctx.user_data != null);

        const project = Project.of(ctx);
        const identity = identity_module.identify(request, ctx.arena, project);
        var session: Session = .{
            .request = request,
            .response = response,
            .arena = ctx.arena,
            .project = project,
            .identity = identity,
            .ctx = identity_module.context(project, ctx.arena, identity.caller),
        };

        _ = identity.csrf_token(project, &session.csrf);

        std.debug.assert(session.ctx.now_ms > 0);

        const now_ms = session.ctx.now_ms;

        identity_module.repair_hint(project, request, response, ctx.arena, &identity, now_ms);

        return session;
    }

    pub fn signed_in(session: *const Session) bool {
        std.debug.assert(session.ctx.now_ms > 0);
        std.debug.assert(session.project.connection.transaction_depth == 0);

        return session.identity.session != null;
    }

    pub fn csrf_token(session: *const Session) []const u8 {
        std.debug.assert(session.signed_in());
        std.debug.assert(session.csrf.len == auth.csrf.token_len);

        return &session.csrf;
    }

    /// Same-origin and, when signed in, a valid `csrf` form field.
    pub fn guard(session: *const Session, form: *const Form) bool {
        std.debug.assert(session.request.method() == .post);
        std.debug.assert(form.len <= form_pairs_max);

        const origin = identity_module.origin_of(session.request);
        const identity_session = session.identity.session orelse return origin != .foreign;

        if (origin != .same) {
            return false;
        }

        const provided = form.get("csrf") orelse "";

        return auth.csrf.verify(session.project.auth.secret, identity_session.id, provided);
    }
};

/// What every signed-in page's chrome needs: who is signed in, the CSRF token for the
/// sign-out form, and the rail sections the viewer's roles open besides Content. The
/// content types go through `nav_items`, typed per view.
pub const Shell = struct {
    user_name: []const u8,
    user_email: []const u8,
    csrf: []const u8,
    /// Structure, for whoever may change a content type.
    can_structure: bool,
    /// Settings, for whoever may manage the accounts.
    can_settings: bool,
};

pub fn shell_of(session: *const Session) Shell {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.identity.email.len > 0);

    return .{
        .user_name = session.identity.display_name,
        .user_email = session.identity.email,
        .csrf = session.csrf_token(),
        .can_structure = registry.SDK.may(&session.ctx, types.Create),
        .can_settings = registry.SDK.may(&session.ctx, users.List),
    };
}

pub const nav = @import("admin/nav.zig");
pub const nav_content = nav.nav_content;

/// Sign-in required, by an account that may use the admin: answers null after
/// redirecting to the login page otherwise.
pub fn require(request: *Request, response: *Response, ctx: *Context) Error!?Session {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(response.headers_len == 0);

    const session = Session.open(request, response, ctx);

    if (!session.signed_in()) {
        try response.redirect(.see_other, "/admin/login");

        return null;
    }

    // An account whose roles reach none of the admin's operations (an app's visitor) is
    // turned back at every admin URL, to the login page that says so.
    if (!registry.SDK.reaches_admin(&session.ctx)) {
        try response.redirect(.see_other, "/admin/login");

        return null;
    }

    return session;
}

/// A one-line failure page with a way back.
pub fn fail(session: *const Session, err: anyerror, back: []const u8) Error!void {
    std.debug.assert(back.len > 0);
    std.debug.assert(@errorName(err).len > 0);

    // A plugin's own failure says what went wrong in its own words.
    const failure = if (err == error.Failed) session.ctx.failure else null;
    const text = if (failure) |declared| declared.message else @errorName(err);

    try message(session, "Something went wrong", text, &.{}, back);
}

/// The problems page: what was refused and why, with a way back. Chromeless when the
/// caller is not signed in (a refused login, a foreign form).
pub fn message(
    session: *const Session,
    heading: []const u8,
    text: []const u8,
    problems: anytype,
    back: []const u8,
) Error!void {
    std.debug.assert(heading.len > 0);
    std.debug.assert(back.len > 0);

    var items: std.ArrayList(views.Message.ProblemsItem) = .empty;

    for (problems) |problem| {
        items.append(session.arena, .{ .path = problem.path, .message = problem.message }) catch {
            return error.OutOfMemory;
        };
    }

    const in_types = std.mem.startsWith(u8, back, "/admin/types") or
        std.mem.startsWith(u8, back, "/admin/taxonomies") or
        std.mem.startsWith(u8, back, "/admin/terms");
    var props: views.Message.Props = .{
        .section = if (in_types) "types" else "content",
        .heading = heading,
        .text = text,
        .problems = items.items,
        .link_href = back,
        .link_label = "Back",
    };

    if (session.signed_in()) {
        const shell = shell_of(session);
        // The sidebar lists the types through an operation, which needs a context it
        // may write to; the page's session is borrowed, so it is copied for that.
        var listing = session.*;

        props.user_name = shell.user_name;
        props.user_email = shell.user_email;
        props.can_structure = shell.can_structure;
        props.can_settings = shell.can_settings;
        props.csrf = shell.csrf;
        if (!in_types) {
            props.nav = try nav_content(&listing, .{});
        }
    }

    try render.page(session.response, session.arena, .ok, views.Message, props);
}

/// Unix milliseconds as `YYYY-MM-DD HH:MM`, UTC.
pub fn time_text(arena: std.mem.Allocator, ms: i64) []const u8 {
    std.debug.assert(ms >= 0);
    std.debug.assert(ms < 1 << 50);

    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(ms, 1000)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    }) catch "";
}

const routes = @import("../server/routes.zig");

pub const Flow = struct {
    inner: routes.testing.Flow,
    cookie: []const u8 = "",

    pub fn call(
        flow: *Flow,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) !http.Response {
        std.debug.assert(method.len > 0);
        std.debug.assert(path.len > 0);

        const head_text = try std.fmt.allocPrint(
            flow.inner.arena,
            "{s} {s} HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\nCookie: {s}\r\n" ++
                "Content-Length: 0\r\n\r\n",
            .{ method, path, flow.cookie },
        );
        const response = try flow.inner.call(head_text, body);

        // The session, as a browser keeps it: the signed-in hint beside it is not it.
        if (response.header("Set-Cookie")) |cookie| {
            if (std.mem.startsWith(u8, cookie, identity_module.cookie_name ++ "=")) {
                flow.cookie = cookie[0..std.mem.indexOfScalar(u8, cookie, ';').?];
            }
        }

        return response;
    }

    fn get_data(flow: *Flow, path: []const u8) !http.Response {
        std.debug.assert(path.len > 0);
        std.debug.assert(flow.cookie.len > 0);

        const head = try std.fmt.allocPrint(
            flow.inner.arena,
            "GET {s} HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n" ++
                "Accept: application/json\r\nContent-Length: 0\r\n\r\n",
            .{ path, flow.cookie },
        );

        return flow.inner.call(head, "");
    }

    /// A fetch from a page's script: `Publr-Fragment` names the fragment wanted.
    fn get_fragment(
        flow: *Flow,
        path: []const u8,
        fragment: []const u8,
        below: []const u8,
    ) !http.Response {
        std.debug.assert(path.len > 0);
        std.debug.assert(fragment.len > 0);

        const head_text = try std.fmt.allocPrint(
            flow.inner.arena,
            "GET {s} HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\nCookie: {s}\r\n" ++
                "Publr-Fragment: {s}\r\nPublr-Below: {s}\r\nContent-Length: 0\r\n\r\n",
            .{ path, flow.cookie, fragment, below },
        );

        return flow.inner.call(head_text, "");
    }

    /// A post from a page's script: the same form, with `Publr-Fragment` naming the answer.
    fn post_fragment(
        flow: *Flow,
        path: []const u8,
        body: []const u8,
        fragment: []const u8,
    ) !http.Response {
        std.debug.assert(path.len > 0);
        std.debug.assert(fragment.len > 0);

        const head_text = try std.fmt.allocPrint(
            flow.inner.arena,
            "POST {s} HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\nCookie: {s}\r\n" ++
                "Publr-Fragment: {s}\r\nContent-Length: 0\r\n\r\n",
            .{ path, flow.cookie, fragment },
        );

        return flow.inner.call(head_text, body);
    }

    pub fn csrf_of(flow: *Flow, html: []const u8) []const u8 {
        std.debug.assert(html.len > 0);
        std.debug.assert(flow.cookie.len > 0);

        const marker = "name=\"csrf\" value=\"";
        const at = std.mem.indexOf(u8, html, marker).? + marker.len;

        return html[at .. at + auth.csrf.token_len];
    }
};

test "admin over http: setup, login, types and content through plain forms" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var flow: Flow = .{ .inner = undefined };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena_state.allocator());

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);

    const fresh = try flow.call("GET", "/admin", "");
    try std.testing.expectEqualStrings("/admin/setup", fresh.header("Location").?);

    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    const created = try flow.call("POST", "/admin/setup", setup_body);
    try std.testing.expectEqualStrings("/admin/content", created.header("Location").?);
    try std.testing.expect(std.mem.startsWith(u8, flow.cookie, "publr_session="));

    const structure = try flow.call("GET", "/admin/structure", "");
    try std.testing.expectEqual(.ok, structure.status);

    const destinations = [_][]const u8{
        "/admin/types",      "/admin/structure/taxonomies", "/admin/structure/settings",
        "/admin/components", "/admin/custom-fields",
    };

    for (destinations) |destination| {
        try std.testing.expect(std.mem.indexOf(u8, structure.body, destination) != null);
        const page = try flow.call("GET", destination, "");
        try std.testing.expectEqual(.ok, page.status);
    }

    const types_page = try flow.call("GET", "/admin/types", "");
    const types_title = "<title>Content types · Publr</title>";
    try std.testing.expect(std.mem.indexOf(u8, types_page.body, types_title) != null);
    const csrf_token = flow.csrf_of(types_page.body);
    const arena = flow.inner.arena;

    const type_body = try std.fmt.allocPrint(
        flow.inner.arena,
        "csrf={s}&kind=record&name=Post&handle=post&has_url=1&url=posts",
        .{csrf_token},
    );
    const type_created = try flow.call("POST", "/admin/types/create", type_body);
    try std.testing.expectEqualStrings("/admin/types/post", type_created.header("Location").?);
    const fields_page = try flow.call("GET", "/admin/types/post", "");
    try std.testing.expect(std.mem.indexOf(u8, fields_page.body, ">Slug</a>") != null);
    const split_button = "data-part=\"split-button\"";
    const form_preview = "data-part=\"form-preview\"";
    const editor_part = "data-part=\"record-editor\"";
    try std.testing.expect(std.mem.indexOf(u8, fields_page.body, split_button) != null);
    try std.testing.expect(std.mem.indexOf(u8, fields_page.body, form_preview) != null);
    try std.testing.expect(std.mem.indexOf(u8, fields_page.body, editor_part) != null);
    const title_body = try std.fmt.allocPrint(
        flow.inner.arena,
        "csrf={s}&kind=string&parent=&name=title&label=Title&required=1&title=1&next=finish",
        .{csrf_token},
    );
    _ = try flow.call("POST", "/admin/types/post/fields/create", title_body);
    const slug_delete = try std.fmt.allocPrint(arena, "csrf={s}", .{csrf_token});
    const kept = try flow.call("POST", "/admin/types/post/fields/slug/delete", slug_delete);
    try std.testing.expect(std.mem.indexOf(u8, kept.body, "needs a slug field") != null);
    const bad_body = try std.fmt.allocPrint(
        flow.inner.arena,
        "csrf={s}&kind=string&parent=&name=Bad+Name&label=Bad&next=finish",
        .{csrf_token},
    );
    const refused = try flow.call("POST", "/admin/types/post/fields/create", bad_body);
    try std.testing.expect(refused.header("Location") == null);
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "field name must be") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "value=\"Bad Name\"") != null);
    const group_body = try std.fmt.allocPrint(
        flow.inner.arena,
        "csrf={s}&kind=repeater&parent=&name=gallery&label=Gallery&next=finish",
        .{csrf_token},
    );
    const group_created = try flow.call("POST", "/admin/types/post/fields/create", group_body);
    const group_page = "/admin/types/post/fields/gallery";
    try std.testing.expectEqualStrings(group_page, group_created.header("Location").?);
    const caption_body = try std.fmt.allocPrint(
        flow.inner.arena,
        "csrf={s}&kind=string&parent=gallery&name=caption&label=Caption&next=finish",
        .{csrf_token},
    );
    const caption_created = try flow.call("POST", "/admin/types/post/fields/create", caption_body);
    try std.testing.expectEqualStrings(group_page, caption_created.header("Location").?);
    const gallery = try flow.call("GET", group_page, "");
    try std.testing.expect(std.mem.indexOf(u8, gallery.body, ">Caption</a>") != null);
    const gallery_level = "data-url=\"/admin/types/post/fields/gallery\"";
    const caption_level = "data-url=\"/admin/types/post/fields/gallery.caption\"";
    try std.testing.expect(std.mem.indexOf(u8, gallery.body, gallery_level) != null);
    try std.testing.expect(std.mem.indexOf(u8, gallery.body, caption_level) == null);
    const caption_path = "/admin/types/post/fields/gallery.caption";
    const caption_page = try flow.call("GET", caption_path, "");
    try std.testing.expect(std.mem.indexOf(u8, caption_page.body, gallery_level) == null);
    try std.testing.expect(std.mem.indexOf(u8, caption_page.body, caption_level) != null);
    try std.testing.expect(std.mem.indexOf(u8, caption_page.body, "id=\"field-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, caption_page.body, ">Fields</a>") != null);
    const caption_panel = try flow.get_fragment(caption_path, "panel", "Gallery");
    try std.testing.expect(std.mem.indexOf(u8, caption_panel.body, "<title>") == null);
    try std.testing.expect(std.mem.indexOf(u8, caption_panel.body, gallery_level) == null);
    try std.testing.expect(std.mem.indexOf(u8, caption_panel.body, ">Gallery</a>") != null);
    const panel_content = "data-part=\"type-panel-content\"";
    try std.testing.expect(std.mem.indexOf(u8, caption_panel.body, panel_content) != null);
    const picker = try flow.call("GET", "/admin/types/post/fields/new", "");
    const text_card = "/admin/types/post/fields/new?kind=text&amp;parent=\"";
    try std.testing.expect(std.mem.indexOf(u8, picker.body, text_card) != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.body, "data-part=\"type-level\"") != null);
    const field_form = try flow.call("GET", "/admin/types/post/fields/new?kind=text", "");
    try std.testing.expect(std.mem.indexOf(u8, field_form.body, "name=\"max_len\"") != null);
    const field_form_part = "data-part=\"field-form\"";
    try std.testing.expect(std.mem.indexOf(u8, field_form.body, field_form_part) != null);
    const preview_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=text&parent=&name=&label=&help=Seen+in+the+preview&next=finish",
        .{csrf_token},
    );
    const create_path = "/admin/types/post/fields/create";
    const previewed = try flow.post_fragment(create_path, preview_body, "preview");
    try std.testing.expect(std.mem.indexOf(u8, previewed.body, "<title>") == null);
    try std.testing.expect(std.mem.indexOf(u8, previewed.body, editor_part) != null);
    try std.testing.expect(std.mem.indexOf(u8, previewed.body, "Untitled field") != null);
    try std.testing.expect(std.mem.indexOf(u8, previewed.body, "Seen in the preview") != null);
    const not_saved = try flow.call("GET", "/admin/types/post", "");
    try std.testing.expect(std.mem.indexOf(u8, not_saved.body, "Untitled field") == null);
    const field_body = try std.fmt.allocPrint(
        flow.inner.arena,
        "csrf={s}&kind=text&parent=&name=body&label=Body&searchable=1&rows=8&many=1&next=another",
        .{csrf_token},
    );
    const field_created = try flow.call("POST", "/admin/types/post/fields/create", field_body);
    const picker_again = "/admin/types/post/fields/new?parent=";
    try std.testing.expectEqualStrings(picker_again, field_created.header("Location").?);
    const with_body = try flow.call("GET", "/admin/types/post", "");
    try std.testing.expect(std.mem.indexOf(u8, with_body.body, ">Body</a>") != null);
    const body_page = try flow.call("GET", "/admin/types/post/fields/body", "");
    try std.testing.expect(std.mem.indexOf(u8, body_page.body, "value=\"8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_page.body, "value=\"1\" checked") != null);
    const move_body = try std.fmt.allocPrint(arena, "csrf={s}&direction=up", .{csrf_token});
    _ = try flow.call("POST", "/admin/types/post/fields/body/move", move_body);
    const reordered = try flow.call("GET", "/admin/types/post", "");
    const body_at = std.mem.indexOf(u8, reordered.body, ">Body</a>").?;
    const gallery_at = std.mem.indexOf(u8, reordered.body, ">Gallery</a>").?;
    try std.testing.expect(body_at < gallery_at);
    const titled = try flow.call("GET", "/admin/types/post", "");
    try std.testing.expect(std.mem.indexOf(u8, titled.body, "Text, the title") != null);
    const panel_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=boolean&parent=&name=flag&label=Flag&next=finish",
        .{csrf_token},
    );
    const panel_saved = try flow.post_fragment(create_path, panel_body, "panel");
    try std.testing.expectEqualStrings("/admin/types/post", panel_saved.header("Publr-Location").?);
    try std.testing.expectEqual(@as(usize, 0), panel_saved.body.len);
    const with_flag = try flow.call("GET", "/admin/types/post", "");
    try std.testing.expect(std.mem.indexOf(u8, with_flag.body, ">Flag</a>") != null);
    const nameless = try std.fmt.allocPrint(arena, "csrf={s}&kind=record&name=&handle=", .{
        csrf_token,
    });
    const head_refused = try flow.call("POST", "/admin/types/create", nameless);
    try std.testing.expect(head_refused.header("Location") == null);
    const inline_error = "data-part=\"field-error\"";
    try std.testing.expect(std.mem.indexOf(u8, head_refused.body, inline_error) != null);
    const described = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=component&name=Seo&handle=seo&description=Meta+tags+of+a+page",
        .{csrf_token},
    );
    _ = try flow.call("POST", "/admin/components/create", described);
    const seo_settings = try flow.call("GET", "/admin/components/seo/settings", "");
    try std.testing.expect(std.mem.indexOf(u8, seo_settings.body, "Meta tags of a page") != null);
    const sku_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=string&parent=&name=sku&label=SKU&unique=1&limit_length=1&min_len=2" ++
            "&max_len=12&length_message=Two+to+twelve&help=As+printed&next=finish",
        .{csrf_token},
    );
    _ = try flow.call("POST", "/admin/types/post/fields/create", sku_body);
    const sku_page = try flow.call("GET", "/admin/types/post/fields/sku", "");
    try std.testing.expect(std.mem.indexOf(u8, sku_page.body, "value=\"Two to twelve\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sku_page.body, "id=\"unique\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sku_page.body, "value=\"As printed\"") != null);
    const no_default = "You cannot set a default value for unique fields.";
    try std.testing.expect(std.mem.indexOf(u8, sku_page.body, no_default) != null);
    const subtitle_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=string&parent=&name=subtitle&label=Subtitle&default=Untitled&next=finish",
        .{csrf_token},
    );
    _ = try flow.call("POST", "/admin/types/post/fields/create", subtitle_body);
    const when_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=datetime&parent=&name=when&label=When&limit_range=1&min=2026-01-01" ++
            "&date_format=date&next=finish",
        .{csrf_token},
    );
    _ = try flow.call("POST", "/admin/types/post/fields/create", when_body);
    const when_page = try flow.call("GET", "/admin/types/post/fields/when", "");
    try std.testing.expect(std.mem.indexOf(u8, when_page.body, "value=\"2026-01-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, when_page.body, "value=\"date\" selected") != null);
    const cover_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=media&parent=&name=cover&label=Cover&limit_size=1&size_max=2" ++
            "&size_max_unit=mb&limit_types=1&media_types=image&media_create=1&media_link=1" ++
            "&next=finish",
        .{csrf_token},
    );
    _ = try flow.call("POST", "/admin/types/post/fields/create", cover_body);
    const cover_page = try flow.call("GET", "/admin/types/post/fields/cover", "");
    try std.testing.expect(std.mem.indexOf(u8, cover_page.body, "value=\"mb\" selected") != null);
    const image_ticked = "name=\"media_types\" value=\"image\" checked";
    try std.testing.expect(std.mem.indexOf(u8, cover_page.body, image_ticked) != null);
    const no_media_default = "Not available for this field type";
    try std.testing.expect(std.mem.indexOf(u8, cover_page.body, no_media_default) != null);
    const flag_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=boolean&parent=&name=featured&label=Featured&true_label=Shown" ++
            "&false_label=Hidden&boolean_control=radio&next=finish",
        .{csrf_token},
    );
    _ = try flow.call("POST", "/admin/types/post/fields/create", flag_body);
    const flag_page = try flow.call("GET", "/admin/types/post/fields/featured", "");
    try std.testing.expect(std.mem.indexOf(u8, flag_page.body, "id=\"required\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, flag_page.body, "value=\"radio\" selected") != null);
    const tone_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=select&parent=&name=tone&label=Tone&many=1&choices=a+%7C+Alpha%0Ab" ++
            "&select_control=list&limit_items=1&items_max=2&next=finish",
        .{csrf_token},
    );
    _ = try flow.call("POST", "/admin/types/post/fields/create", tone_body);
    const tone_page = try flow.call("GET", "/admin/types/post/fields/tone", "");
    try std.testing.expect(std.mem.indexOf(u8, tone_page.body, "a | Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, tone_page.body, "id=\"limit_items\"") != null);
    const site_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=url&parent=&name=site&label=Site&limit_schemes=1&schemes=https" ++
            "&limit_hosts=1&hosts=publr.dev&next=finish",
        .{csrf_token},
    );
    _ = try flow.call("POST", "/admin/types/post/fields/create", site_body);
    const site_page = try flow.call("GET", "/admin/types/post/fields/site", "");
    const https_ticked = "name=\"schemes\" value=\"https\" checked";
    try std.testing.expect(std.mem.indexOf(u8, site_page.body, https_ticked) != null);
    try std.testing.expect(std.mem.indexOf(u8, site_page.body, ">publr.dev</textarea>") != null);
    const seeded_page = try flow.call("GET", "/admin/content/new?type=post", "");
    try std.testing.expect(std.mem.indexOf(u8, seeded_page.body, "value=\"Untitled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, seeded_page.body, "As printed") != null);
    try std.testing.expect(std.mem.indexOf(u8, seeded_page.body, "type=\"date\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, seeded_page.body, ">Shown</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, seeded_page.body, "name=\"tone[0]\"") != null);
    const new_entry_page = try flow.call("GET", "/admin/content/new?type=post", "");
    try std.testing.expect(std.mem.indexOf(u8, new_entry_page.body, "name=\"title\"") != null);

    const settings_body = try std.fmt.allocPrint(
        flow.inner.arena,
        "csrf={s}&kind=settings&name=Homepage&public=1",
        .{csrf_token},
    );
    const settings_created = try flow.call(
        "POST",
        "/admin/structure/settings/create",
        settings_body,
    );
    const settings_page_location = settings_created.header("Location").?;
    try std.testing.expectEqualStrings(
        "/admin/structure/settings/homepage",
        settings_page_location,
    );
    const settings_content = try flow.call("GET", "/admin/content?type=homepage", "");
    const settings_location = settings_content.header("Location").?;
    try std.testing.expectEqualStrings("/admin/settings/homepage", settings_location);
    const settings_again = try flow.call("GET", "/admin/content?type=homepage", "");
    try std.testing.expectEqualStrings(settings_location, settings_again.header("Location").?);

    const no_csrf = try flow.call("POST", "/admin/content/create", "type=post&title=Nope");
    try std.testing.expect(std.mem.indexOf(u8, no_csrf.body, "RefusedCrossSite") != null);

    const entry_body = try std.fmt.allocPrint(arena, "csrf={s}&type=post&title=Hello", .{
        csrf_token,
    });
    const entry_created = try flow.call("POST", "/admin/content/create", entry_body);
    const location = entry_created.header("Location").?;
    try std.testing.expect(std.mem.startsWith(u8, location, "/admin/content/"));

    const edit_page = try flow.call("GET", location, "");
    try std.testing.expect(std.mem.indexOf(u8, edit_page.body, "value=\"Hello\"") != null);
    const publish_button = ">Publish</span>";
    try std.testing.expect(std.mem.indexOf(u8, edit_page.body, publish_button) != null);

    const publish_path = try std.fmt.allocPrint(arena, "{s}/action", .{location});
    const publish_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&do=publish&expected_version=1",
        .{csrf_token},
    );
    _ = try flow.call("POST", publish_path, publish_body);
    const published = try flow.call("GET", location, "");
    const published_marker = ">Published</";
    try std.testing.expect(std.mem.indexOf(u8, published.body, published_marker) != null);

    const save_path = try std.fmt.allocPrint(arena, "{s}/save", .{location});
    const parked_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&title=Hello+again&expected_version=2",
        .{csrf_token},
    );
    _ = try flow.call("POST", save_path, parked_body);
    const changed = try flow.call("GET", location, "");
    try std.testing.expect(std.mem.indexOf(u8, changed.body, "unpublished changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed.body, "value=\"Hello again\"") != null);
    const revisions_path = try std.fmt.allocPrint(arena, "{s}/revisions", .{location});
    const versions = try flow.call("GET", revisions_path, "");
    try std.testing.expect(std.mem.indexOf(u8, versions.body, ">revision</span>") == null);
    _ = try flow.call("GET", location, "");

    const publish_changes = ">Publish changes</span>";
    const discard_changes = ">Discard changes</span>";
    try std.testing.expect(std.mem.indexOf(u8, changed.body, publish_changes) != null);
    try std.testing.expect(std.mem.indexOf(u8, changed.body, discard_changes) != null);

    const invalid_body = try std.fmt.allocPrint(arena, "csrf={s}&type=post", .{csrf_token});
    const invalid = try flow.call("POST", "/admin/content/create", invalid_body);
    const problem_path = ">title</code>";
    const problem_message = ">required</span>";
    try std.testing.expect(std.mem.indexOf(u8, invalid.body, problem_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid.body, problem_message) != null);

    const apply_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&do=publish&expected_version=3",
        .{csrf_token},
    );
    _ = try flow.call("POST", publish_path, apply_body);
    const with_versions = try flow.call("GET", revisions_path, "");
    try std.testing.expect(std.mem.indexOf(u8, with_versions.body, ">revision</span>") != null);
    const first_version = try std.fmt.allocPrint(arena, "{s}/revisions/1", .{location});
    const shown = try flow.call("GET", first_version, "");
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "&quot;Hello&quot;") != null);
    const restore_path = try std.fmt.allocPrint(arena, "{s}/restore", .{location});
    const restore_body = try std.fmt.allocPrint(arena, "csrf={s}&seq=1&expected_version=4", .{
        csrf_token,
    });
    const restored = try flow.call("POST", restore_path, restore_body);
    try std.testing.expectEqualStrings(location, restored.header("Location").?);
    const after_restore = try flow.call("GET", location, "");
    try std.testing.expect(std.mem.indexOf(u8, after_restore.body, "value=\"Hello\"") != null);
    const parked_note = "unpublished changes";
    try std.testing.expect(std.mem.indexOf(u8, after_restore.body, parked_note) != null);

    const all_content = try flow.call("GET", "/admin/content", "");
    const filter_bar = "data-part=\"filter-bar\"";
    try std.testing.expect(std.mem.indexOf(u8, all_content.body, filter_bar) != null);
    const all_title = "<title>All content · Publr</title>";
    try std.testing.expect(std.mem.indexOf(u8, all_content.body, all_title) != null);
    try std.testing.expect(std.mem.indexOf(u8, all_content.body, ">Private views<") != null);
    const list_data = try flow.get_data("/admin/content?types=post");
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, list_data.body, .{});
    defer parsed.deinit();
    const envelope = parsed.value.object;
    try std.testing.expect(envelope.get("html") == null);
    const data = envelope.get("data").?.object;
    try std.testing.expectEqualStrings("/admin/content?types=post", data.get("address").?.string);
    try std.testing.expect(data.get("rows").?.array.items.len > 0);
    try std.testing.expect(data.get("columns").?.array.items.len > 0);
    try std.testing.expect(data.get("filters").?.array.items.len > 0);
    try std.testing.expectEqualStrings("Accept", list_data.header("Vary").?);
    try std.testing.expectEqualStrings("private, no-cache", list_data.header("Cache-Control").?);
    const typed = try flow.call("GET", "/admin/content?type=post&status=", "");
    try std.testing.expect(std.mem.indexOf(u8, typed.body, "<title>Post · Publr</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed.body, "data-part=\"filter-pill\"") != null);
    const view_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&name=Post+drafts&filters=type%3Dpost%26status%3Ddraft",
        .{csrf_token},
    );
    const view_created = try flow.call("POST", "/admin/views/create", view_body);
    const view_location = view_created.header("Location").?;
    const view_prefix = "/admin/content?view=";
    try std.testing.expect(std.mem.startsWith(u8, view_location, view_prefix));
    const view_page = try flow.call("GET", view_location, "");
    const view_title = "<title>Post drafts · Publr</title>";
    try std.testing.expect(std.mem.indexOf(u8, view_page.body, view_title) != null);
    try std.testing.expect(std.mem.indexOf(u8, view_page.body, ">Draft</span>") != null);
    const changed_path = try std.fmt.allocPrint(arena, "{s}&type=post&status=published", .{
        view_location,
    });
    const changed_view = try flow.call("GET", changed_path, "");
    const save_item = "Save changes to this view";
    try std.testing.expect(std.mem.indexOf(u8, changed_view.body, save_item) != null);
    const original_data = try flow.get_data(view_location);
    const unchanged = "\"view_changed\":false";
    try std.testing.expect(std.mem.indexOf(u8, original_data.body, unchanged) != null);
    const view_id = view_location[view_prefix.len..];
    const rename_path = try std.fmt.allocPrint(arena, "/admin/views/{s}/rename", .{view_id});
    const rename_body = try std.fmt.allocPrint(arena, "csrf={s}&name=Drafts+of+posts", .{
        csrf_token,
    });
    const renamed = try flow.call("POST", rename_path, rename_body);
    try std.testing.expectEqualStrings(view_location, renamed.header("Location").?);
    const view_save_path = try std.fmt.allocPrint(arena, "/admin/views/{s}/save", .{view_id});
    const view_save_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&filters=type%3Dpost%26status%3Dpublished",
        .{csrf_token},
    );
    _ = try flow.call("POST", view_save_path, view_save_body);
    const saved_view = try flow.call("GET", view_location, "");
    const saved_title = "<title>Drafts of posts · Publr</title>";
    try std.testing.expect(std.mem.indexOf(u8, saved_view.body, saved_title) != null);
    try std.testing.expect(std.mem.indexOf(u8, saved_view.body, ">Published</span>") != null);
    const saved_data = try flow.get_data(view_location);
    try std.testing.expect(std.mem.indexOf(u8, saved_data.body, "\"view_changed\":false") != null);
    const delete_path = try std.fmt.allocPrint(arena, "/admin/views/{s}/delete", .{view_id});
    const delete_body = try std.fmt.allocPrint(arena, "csrf={s}", .{csrf_token});
    const deleted = try flow.call("POST", delete_path, delete_body);
    try std.testing.expectEqualStrings("/admin/content", deleted.header("Location").?);
    const gone = try flow.call("GET", view_location, "");
    try std.testing.expect(std.mem.indexOf(u8, gone.body, "NotFound") != null);

    const taxonomy_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&name=Topics&handle=topics&description=&hierarchical=1&public=1&applies_to=post",
        .{csrf_token},
    );
    const taxonomy_created = try flow.call("POST", "/admin/taxonomies/create", taxonomy_body);
    const taxonomy_location = taxonomy_created.header("Location").?;
    try std.testing.expectEqualStrings("/admin/taxonomies/topics", taxonomy_location);
    const taxonomies_page = try flow.call("GET", "/admin/taxonomies", "");
    try std.testing.expect(std.mem.indexOf(u8, taxonomies_page.body, "<title>Taxonomies") != null);
    try std.testing.expect(std.mem.indexOf(u8, taxonomies_page.body, ">Topics</a>") != null);
    const empty_terms = try flow.call("GET", "/admin/taxonomies/topics", "");
    try std.testing.expect(std.mem.indexOf(u8, empty_terms.body, "No terms yet") != null);
    const term_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&type=topics&name=Technology",
        .{csrf_token},
    );
    const term_created = try flow.call("POST", "/admin/terms/create", term_body);
    const term_location = term_created.header("Location").?;
    try std.testing.expect(std.mem.startsWith(u8, term_location, "/admin/terms/"));
    const term_page = try flow.call("GET", term_location, "");
    try std.testing.expect(std.mem.indexOf(u8, term_page.body, "name=\"parent\"") != null);
    const child_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&type=topics&name=Engineering&parent={s}",
        .{ csrf_token, term_location["/admin/terms/".len..] },
    );
    _ = try flow.call("POST", "/admin/terms/create", child_body);
    const terms_page = try flow.call("GET", "/admin/taxonomies/topics", "");
    try std.testing.expect(std.mem.indexOf(u8, terms_page.body, ">Technology</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, terms_page.body, ">Engineering</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, terms_page.body, "pl-4") != null);
    const topics_field = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=terms&parent=&name=themes&label=Themes&many=1&taxonomy=topics&next=finish",
        .{csrf_token},
    );
    const topics_added = try flow.call("POST", "/admin/types/post/fields/create", topics_field);
    try std.testing.expectEqualStrings("/admin/types/post", topics_added.header("Location").?);
    const with_topics = try flow.call("GET", "/admin/types/post", "");
    try std.testing.expect(std.mem.indexOf(u8, with_topics.body, "Terms (many) of topics") != null);
    const terms_summary = "Terms (many) of topics";
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, with_topics.body, terms_summary));
    const new_post = try flow.call("GET", "/admin/content/new?type=post", "");
    const terms_part = "data-part=\"record-terms\"";
    try std.testing.expect(std.mem.indexOf(u8, new_post.body, terms_part) != null);
    try std.testing.expect(std.mem.indexOf(u8, new_post.body, "data-part=\"term-tree\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, new_post.body, "Engineering") != null);
    try std.testing.expect(std.mem.indexOf(u8, new_post.body, "form=\"record\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, new_post.body, "id=\"field-themes-") != null);
    const settings = try flow.call("GET", "/admin/taxonomies/topics/settings", "");
    try std.testing.expect(std.mem.indexOf(u8, settings.body, "id=\"applies-post\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings.body, "value=\"post\" checked") != null);

    const logout_body = try std.fmt.allocPrint(arena, "csrf={s}", .{csrf_token});
    _ = try flow.call("POST", "/admin/logout", logout_body);
    const after = try flow.call("GET", "/admin/content", "");
    try std.testing.expectEqualStrings("/admin/login", after.header("Location").?);
}

test "a settings type uses the shared editor and publishes only after a guarded write" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var flow: Flow = .{ .inner = undefined };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);
    const locked = try flow.call("GET", "/admin/settings", "");
    try std.testing.expect(locked.header("Location") != null);
    _ = try flow.call(
        "POST",
        "/admin/setup",
        "email=ada%40example.com&display_name=Ada&password=correct+horse+battery",
    );
    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    const records = @import("../operations/record.zig");
    const content_type = @import("../model/content_type.zig");
    const website: content_type.Def = .{
        .handle = "website",
        .name = "Website",
        .kind = .settings,
        .title_field = "",
        .fields = &.{
            .{ .name = "hero_title", .label = "Hero title", .kind = "text" },
            .{ .name = "fees", .label = "Fee rows", .kind = "repeater", .fields = &.{
                .{ .name = "label", .label = "Label", .kind = "string" },
            } },
        },
    };
    try records.fixture.post_type(&system);
    _ = try registry.SDK.dispatch(&system, types.Create, .{
        .definition = try content_type.encode(arena, website),
    });
    const record = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "post",
        .document = "{\"title\":\"A post\"}",
        .status = "published",
    });
    const index = try flow.call("GET", "/admin/settings", "");
    try std.testing.expectEqualStrings("/admin/settings/system", index.header("Location").?);
    const page = try flow.call("GET", "/admin/settings/website", "");
    try std.testing.expectEqual(.ok, page.status);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "Hero title") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "Fee rows") != null);
    const csrf = flow.csrf_of(page.body);
    _ = try flow.call(
        "POST",
        "/admin/content/create",
        "csrf=wrong&type=website&hero_title=Welcome+home",
    );
    const before = try registry.SDK.dispatch(&system, records.List, .{ .type = "website" });
    try std.testing.expectEqual(@as(usize, 0), before.records.len);
    _ = try flow.call(
        "POST",
        "/admin/content/create",
        try std.fmt.allocPrint(arena, "csrf={s}&type=website&hero_title=Welcome+home", .{csrf}),
    );
    const after = try registry.SDK.dispatch(&system, records.List, .{ .type = "website" });
    try std.testing.expectEqual(@as(usize, 1), after.records.len);
    try std.testing.expectEqualStrings("draft", after.records[0].status);
    _ = try registry.SDK.dispatch(&system, records.Publish, .{ .id = after.records[0].id });
    const home = try registry.SDK.dispatch(&system, records.Get, .{ .id = after.records[0].id });
    try std.testing.expect(std.mem.indexOf(u8, home.document, "Welcome home") != null);
    const content = try registry.SDK.dispatch(&system, records.List, .{});
    try std.testing.expectEqual(@as(usize, 1), content.records.len);
    try std.testing.expectEqualStrings(record.id, content.records[0].id);
    const all_content = try flow.call("GET", "/admin/content", "");
    try std.testing.expectEqual(.ok, all_content.status);
    try std.testing.expect(std.mem.indexOf(u8, all_content.body, record.id) != null);
    try std.testing.expect(std.mem.indexOf(u8, all_content.body, after.records[0].id) == null);
    const shown = try flow.call("GET", "/admin/settings/website", "");
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "Welcome home") != null);
}

test "settings and custom fields have isolated authoring and validated field forms" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var flow: Flow = .{ .inner = undefined };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);
    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    _ = try flow.call(
        "POST",
        "/admin/setup",
        "email=ada%40example.com&display_name=Ada&password=correct+horse+battery",
    );
    const empty = try flow.call("GET", "/admin/custom-fields", "");
    try std.testing.expect(std.mem.indexOf(u8, empty.body, "No field groups yet") != null);
    const new_group = try flow.call("GET", "/admin/custom-fields/new", "");
    const group_csrf = flow.csrf_of(new_group.body);
    const group_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&name=Author+details&handle=user&active=on&" ++
            "location.0.0.field=destination&location.0.0.value=user",
        .{group_csrf},
    );
    const group_created = try flow.call("POST", "/admin/custom-fields/create", group_body);
    try std.testing.expectEqualStrings(
        "/admin/custom-fields/user",
        group_created.header("Location").?,
    );
    const fields_page = try flow.call("GET", "/admin/custom-fields/user", "");
    try std.testing.expectEqual(.ok, fields_page.status);
    const csrf = flow.csrf_of(fields_page.body);
    const field = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=text&name=biography&label=Biography&next=finish",
        .{
            csrf,
        },
    );
    const created = try flow.call("POST", "/admin/custom-fields/user/fields/create", field);
    try std.testing.expectEqualStrings("/admin/custom-fields/user", created.header("Location").?);
    const saved = try flow.call("GET", "/admin/custom-fields/user", "");
    try std.testing.expect(std.mem.indexOf(
        u8,
        saved.body,
        "/admin/custom-fields/user/fields/biography",
    ) != null);
    const media = try flow.call("GET", "/admin/custom-fields/media", "");
    try std.testing.expect(std.mem.indexOf(u8, media.body, "Biography") == null);
    const invalid = try flow.call("GET", "/admin/custom-fields/settings", "");
    try std.testing.expect(invalid.status != .ok or std.mem.indexOf(
        u8,
        invalid.body,
        "NotFound",
    ) != null);
    const section = try std.fmt.allocPrint(arena, "csrf={s}&name=Brand&handle=brand", .{csrf});
    _ = try flow.call("POST", "/admin/structure/settings/create", section);
    const got = try registry.SDK.dispatch(&system, types.Get, .{ .type = "brand" });
    try std.testing.expectEqual(
        @import("../model.zig").content_type.Kind.settings,
        got.definition.kind,
    );
    try std.testing.expect(!got.definition.public);
    const value_page = try flow.call("GET", "/admin/settings/brand", "");
    try std.testing.expectEqual(.ok, value_page.status);
    try std.testing.expect(std.mem.indexOf(u8, value_page.body, "/admin/settings/brand") != null);
    const entries = try registry.SDK.dispatch(
        &system,
        @import("../operations/record.zig").List,
        .{
            .type = "brand",
        },
    );
    try std.testing.expectEqual(@as(usize, 0), entries.records.len);
    _ = try flow.call("POST", "/admin/structure/settings/brand/fields/create", field);
    const value_form = try flow.call("GET", "/admin/settings/brand", "");
    try std.testing.expect(std.mem.indexOf(u8, value_form.body, "name=\"biography\"") != null);
    const filled = try flow.call("POST", "/admin/content/create", try std.fmt.allocPrint(
        arena,
        "csrf={s}&type=brand&biography=Our+story",
        .{csrf},
    ));
    try std.testing.expect(filled.header("Location") != null);
    const stored = try registry.SDK.dispatch(&system, @import("../operations/record.zig").List, .{
        .type = "brand",
    });
    try std.testing.expectEqual(@as(usize, 1), stored.records.len);
    const reopen = try flow.call("GET", "/admin/settings/brand", "");
    try std.testing.expect(std.mem.indexOf(u8, reopen.body, "Our story") != null);

    const types_page = try flow.call("GET", "/admin/types", "");
    try std.testing.expect(std.mem.indexOf(u8, types_page.body, "/admin/types/brand") == null);
    const cross = try flow.call(
        "POST",
        "/admin/types/brand/delete",
        try std.fmt.allocPrint(
            arena,
            "csrf={s}&force=1",
            .{
                csrf,
            },
        ),
    );
    try std.testing.expect(cross.header("Location") == null);
    _ = try registry.SDK.dispatch(&system, types.Get, .{ .type = "brand" });
}

test "schema creation pages fit a fixed request arena with many field definitions" {
    const model = @import("../model.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var flow: Flow = .{ .inner = undefined };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);
    var system = harness.ctx(.system);
    system.arena = arena;
    try registry.SDK.bootstrap(&system);
    _ = try flow.call(
        "POST",
        "/admin/setup",
        "email=arena%40example.com&display_name=Arena&password=correct+horse+battery",
    );
    var fields: [model.field.fields_max]model.field.Def = undefined;

    for (&fields, 0..) |*field, index| {
        field.* = .{
            .name = try std.fmt.allocPrint(arena, "field_{d}", .{index}),
            .label = "A configurable field",
            .kind = "string",
        };
    }

    for (0..64) |index| {
        const def: model.content_type.Def = .{
            .handle = try std.fmt.allocPrint(arena, "type_{d}", .{index}),
            .name = "A configurable type",
            .fields = &fields,
        };
        _ = try registry.SDK.dispatch(&system, types.Create, .{
            .definition = try model.content_type.encode(arena, def),
        });
    }
    // Same 4 MiB scratch budget as the HTTP server, reset for every request.
    const buffer = try arena.alloc(u8, 4 << 20);
    var fixed = std.heap.FixedBufferAllocator.init(buffer);

    for ([_][]const u8{
        "/admin/structure/settings/new", "/admin/types/new",
        "/admin/components/new",         "/admin/taxonomies/new",
    }) |path| {
        fixed.reset();
        flow.inner.arena = fixed.allocator();
        const page = try flow.call("GET", path, "");
        try std.testing.expectEqual(.ok, page.status);
        try std.testing.expect(std.mem.indexOf(u8, page.body, "Create and add") != null);
    }
}
