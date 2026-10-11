const std = @import("std");
const admin = @import("../admin.zig");
const jit = @import("publr_jit");
const App = @import("../apps/state.zig").App;
const files = @import("design/files.zig");

const Session = admin.Session;

pub const tokens_max: u32 = 1024;

const Token = struct {
    name: []const u8,
    value: []const u8,
};
const Site = struct {
    styles: []const []const u8,
    theme: []const Token,
};

/// What the block editor's canvas needs to draw a record as its app's pages do: the
/// app's compiled stylesheet, and the design tokens the app declares (the ones that are
/// not the stylesheet's defaults), as JSON for `data-editor-site`. With no app to
/// draw with (several apps, none scoped), the editor's own reset only.
pub fn json(session: *const Session, app_name: ?[]const u8) admin.Error![]const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.project.apps.len <= 1024);

    const arena = session.arena;
    const reset = "/admin/editor/preflight.css";
    const app = find(session, app_name) orelse {
        const bare: Site = .{
            .styles = &.{reset},
            .theme = &.{},
        };

        return std.json.Stringify.valueAlloc(arena, bare, .{});
    };
    const styles = try arena.alloc([]const u8, 2);

    styles[0] = reset;
    styles[1] = try std.fmt.allocPrint(arena, "{s}/_app/app.css", .{stylesheet_base(app)});

    const site: Site = .{
        .styles = styles,
        .theme = try theme(arena, app),
    };

    return std.json.Stringify.valueAlloc(arena, site, .{});
}

/// The record's app, else the one the admin is scoped to, else the only app: the app
/// whose tokens and stylesheet the editor draws with, chosen as the Design pages choose.
fn find(session: *const Session, app_name: ?[]const u8) ?*const App {
    std.debug.assert(session.signed_in());
    std.debug.assert(app_name == null or app_name.?.len <= 32);

    return files.app_of(session, app_name);
}

/// Where the app's own files are served from: its path on this host, or its subdomain.
fn stylesheet_base(app: *const App) []const u8 {
    std.debug.assert(app.url.len > 0);
    std.debug.assert(app.spec.name.len > 0);

    return switch (app.spec.mount) {
        .subdomain => app.url,
        .path => app.base(),
    };
}

/// The app's tokens the editor scales its style controls by (font sizes, colors,
/// spacing, radii, fonts, containers), defaults included, then what its design declares:
/// the canvas compiles the same set, and a default token compiles to its default.
fn theme(arena: std.mem.Allocator, app: *const App) admin.Error![]const Token {
    std.debug.assert(app.spec.tokens.tokens.len <= tokens_max * 8);
    std.debug.assert(jit.default_theme.tokens.len > 0);

    var out: std.ArrayList(Token) = .empty;

    for (jit.default_theme.tokens) |token| {
        if (out.items.len == tokens_max) {
            break;
        }

        if (scaled(token.name) and !declares(app, token.name)) {
            try out.append(arena, .{
                .name = token.name,
                .value = token.value,
            });
        }
    }

    for (try declared(arena, app)) |token| {
        if (out.items.len == tokens_max) {
            break;
        }

        try out.append(arena, token);
    }

    return out.items;
}

/// The namespaces a style control offers as its scale.
fn scaled(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    const prefixes = [_][]const u8{
        "text-",
        "leading-",
        "tracking-",
        "spacing-",
        "radius-",
        "font-",
        "container-",
    };

    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            const weight = std.mem.startsWith(u8, name, "font-weight-");

            return std.mem.indexOf(u8, name, "--") == null and !weight;
        }
    }

    return false;
}

fn declares(app: *const App, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (app.spec.tokens.tokens) |token| {
        if (std.mem.eql(u8, token.name, name)) {
            return !is_default(token.name, token.value);
        }
    }

    return false;
}

/// The app's tokens that differ from the stylesheet's defaults: what its design declares.
fn declared(arena: std.mem.Allocator, app: *const App) admin.Error![]const Token {
    std.debug.assert(app.spec.tokens.tokens.len <= tokens_max * 8);
    std.debug.assert(jit.default_theme.tokens.len > 0);

    var out: std.ArrayList(Token) = .empty;

    for (app.spec.tokens.tokens) |token| {
        if (out.items.len == tokens_max) {
            break;
        }

        if (!is_default(token.name, token.value)) {
            try out.append(arena, .{
                .name = token.name,
                .value = token.value,
            });
        }
    }

    return out.items;
}

fn is_default(name: []const u8, value: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(jit.default_theme.tokens.len > 0);

    for (jit.default_theme.tokens) |token| {
        if (std.mem.eql(u8, token.name, name)) {
            return std.mem.eql(u8, token.value, value);
        }
    }

    return false;
}
