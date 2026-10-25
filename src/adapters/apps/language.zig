//! The language a site's page speaks: `Publr.t` in its templates and its interactive
//! components reads the catalogue of the page's language (`Publr.build.locale()`), on the
//! server and, through `<mount>/_app/messages/<locale>.js`, in the browser. A page in
//! English, or in a language no plugin translates, shows the source text.
const std = @import("std");
const runtime = @import("runtime");
const languages = @import("../../server/languages.zig");
const context_module = @import("context.zig");
const model_variant = @import("../../model/variant.zig");

const Context = context_module.Context;
const Project = @import("../../server/project.zig").Project;

/// Where a language's catalogue is among an app's assets: `messages/pl.js`.
pub const messages_prefix = "messages/";

pub const Language = struct {
    locale: []const u8 = "",
    /// The page's `runtime.Translator`; null for English.
    translator: ?*const anyopaque = null,
    /// The catalogue as the script the render's engine and the browser read.
    catalogue: []const u8 = "",
};

/// The page's language, with its catalogue when a plugin translates it.
pub fn of(ctx: *const Context) !Language {
    std.debug.assert(ctx.place.locale.len <= model_variant.code_len_max);

    const found = find(ctx.project, ctx.place.locale) orelse return .{
        .locale = ctx.place.locale,
    };
    const translator = try ctx.arena.create(runtime.Translator);

    translator.* = .{
        .context = &found.catalog,
        .lookup = languages.lookup,
    };

    std.debug.assert(found.script.len > 0);

    return .{
        .locale = found.locale,
        .translator = translator,
        .catalogue = found.script,
    };
}

/// The language a plugin translates by its code; null for English, or none listed.
pub fn find(project: *const Project, locale: []const u8) ?*const languages.Language {
    std.debug.assert(project.languages == null or
        project.languages.?.list.len <= languages.languages_max);

    if (locale.len == 0) {
        return null;
    }

    const all = project.languages orelse return null;

    return all.find(locale);
}

/// The browser's catalogue, before the page's interactive components start: a plain
/// script, so it runs ahead of their modules. Nothing for English.
pub fn write_script(ctx: *const Context, writer: *std.Io.Writer, base: []const u8) !void {
    std.debug.assert(ctx.app.version.len == 16);

    const found = find(ctx.project, ctx.place.locale) orelse return;

    // By what the script holds: a pack updated in place is fetched again.
    try writer.print("<script src=\"{s}{s}{s}{s}.js?v={s}-{x}\"></script>", .{
        base,
        context_module.assets_prefix,
        messages_prefix,
        found.locale,
        &ctx.app.version,
        std.hash.Wyhash.hash(0, found.script),
    });
}

/// `messages/<locale>.js` among an app's assets: the catalogue's script; null when no
/// plugin translates that language.
pub fn script_of(project: *const Project, path: []const u8) ?[]const u8 {
    std.debug.assert(path.len > 0);

    if (!std.mem.startsWith(u8, path, messages_prefix) or !std.mem.endsWith(u8, path, ".js")) {
        return null;
    }

    const locale = path[messages_prefix.len .. path.len - ".js".len];
    const found = find(project, locale) orelse return null;

    return found.script;
}
