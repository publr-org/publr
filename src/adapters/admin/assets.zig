//! The admin's own files: its stylesheet, the stores, the class book, the PublrJS runtime and
//! the block editor, all under `/admin/assets/<version>/`. The version is a hash of every one
//! of them (`build/admin_assets.zig`), so a browser keeps them for a year and asks again only
//! when a new Publr changes one. The scripts import each other by relative paths, so the whole
//! graph follows the folder. A path with another version (a tab open across an update) gets
//! today's files, kept by no one.
const std = @import("std");
const admin = @import("../admin.zig");
const http = @import("../../lib/http.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;

pub const version: []const u8 = @import("admin_asset_version").version;
/// Where the admin's files are, before a project's base path.
pub const base = admin.render.assets_base;
pub const prefix = "/admin/assets/";
pub const routes_count: u32 = 1;

const kept = "public, max-age=31536000, immutable";
const not_kept = "no-cache";

const client_files = @import("../../ui/client_files.zig");
const editor_files = @import("editor_files").files;
const styles_css = @embedFile("styles_css");
const stores_js = @embedFile("admin_stores_js");
/// The admin's class book for the browser's merge, installed before any store runs.
const class_book_js = "import { useClassBook } from \"./publr-class-merge.js\";\n" ++
    "useClassBook(" ++ @embedFile("admin_class_book_json") ++ ");\n";

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len < router.routes.len);
    std.debug.assert(version.len == 16);

    router.get(prefix ++ "*", &serve);
}

/// One of the admin's files, by its path after the version; an installed plugin's views'
/// script at `plugin/<name>/stores.js`.
fn serve(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(std.mem.startsWith(u8, request.path(), prefix));
    std.debug.assert(ctx.user_data != null);

    const after = request.path()[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return not_found(response);
    const current = std.mem.eql(u8, after[0..slash], version);
    const path = after[slash + 1 ..];

    if (std.mem.startsWith(u8, path, "plugin/")) {
        return @import("frame.zig").stores(request, response, ctx, path["plugin/".len..], current);
    }

    const file = embedded(path) orelse return not_found(response);

    try response.set_body(.ok, type_of(path), file);
    try cache(response, current);

    if (std.mem.endsWith(u8, path, ".js")) {
        try allow_frames(response);
    }
}

/// An admin script, as `serve` sends one: kept for a year when `current`.
pub fn script(response: *Response, source: []const u8, current: bool) Error!void {
    std.debug.assert(source.len > 0);
    std.debug.assert(response.body.len == 0);

    try response.set_body(.ok, "text/javascript; charset=utf-8", source);
    try cache(response, current);
    try allow_frames(response);
}

fn embedded(path: []const u8) ?[]const u8 {
    std.debug.assert(path.len < 1 << 16);
    std.debug.assert(styles_css.len > 0);

    if (std.mem.eql(u8, path, "styles.css")) {
        return styles_css;
    }

    if (std.mem.eql(u8, path, "stores.js")) {
        return stores_js;
    }

    if (std.mem.eql(u8, path, "class-book.js")) {
        return class_book_js;
    }

    inline for (client_files.names) |name| {
        if (std.mem.eql(u8, path, name ++ ".js")) {
            return @embedFile(name);
        }
    }

    if (std.mem.startsWith(u8, path, "editor/")) {
        for (editor_files) |file| {
            if (std.mem.eql(u8, file.path, path["editor/".len..])) {
                return file.data;
            }
        }
    }

    return null;
}

fn cache(response: *Response, current: bool) Error!void {
    std.debug.assert(response.body.len > 0);
    std.debug.assert(kept.len > not_kept.len);

    try response.set_header("Cache-Control", if (current) kept else not_kept);
}

/// The plugin frame has an opaque origin, and a module script it loads needs this; the
/// admin's scripts carry no data, only code every visitor of the login page gets.
fn allow_frames(response: *Response) Error!void {
    std.debug.assert(response.body.len > 0);
    std.debug.assert(response.status == .ok);

    try response.set_header("Access-Control-Allow-Origin", "*");
}

fn not_found(response: *Response) Error!void {
    std.debug.assert(response.body.len == 0);
    std.debug.assert(response.status == .ok);

    try response.set_body(.not_found, "text/plain; charset=utf-8", "Not Found");
}

fn type_of(path: []const u8) []const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] != '/');

    if (std.mem.endsWith(u8, path, ".js")) {
        return "text/javascript; charset=utf-8";
    }

    if (std.mem.endsWith(u8, path, ".css")) {
        return "text/css; charset=utf-8";
    }

    if (std.mem.endsWith(u8, path, ".wasm")) {
        return "application/wasm";
    }

    // The canvas page, which the editor's frame loads so it is served as the admin is.
    if (std.mem.endsWith(u8, path, ".html")) {
        return "text/html; charset=utf-8";
    }

    return "text/plain; charset=utf-8";
}

test "the version is sixteen hex digits, and the base path carries it" {
    try std.testing.expectEqual(@as(usize, 16), version.len);
    try std.testing.expect(std.mem.endsWith(u8, base, version));

    for (version) |digit| {
        try std.testing.expect(std.ascii.isHex(digit));
    }
}

test "every file the admin serves is found by its path, and nothing else is" {
    try std.testing.expect(embedded("styles.css") != null);
    try std.testing.expect(embedded("stores.js") != null);
    try std.testing.expect(embedded("class-book.js") != null);
    try std.testing.expect(embedded("publr.js") != null);
    try std.testing.expect(embedded("editor/" ++ editor_files[0].path) != null);
    try std.testing.expect(embedded("../etc/passwd") == null);
    try std.testing.expect(embedded("editor/") == null);
}
