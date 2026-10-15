//! The language the admin speaks to the person signed in: their catalogue handed to every
//! render (`Publr.t` on the server), and the same catalogue as a script for the browser's
//! (`/admin/messages/<locale>.js`, which sets what `Publr.t` reads there).
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const server_languages = @import("../../server/languages.zig");
const runtime = @import("runtime");
const language_operations = @import("../../operations/user/language.zig");

const Session = admin.Session;
const Request = admin.render.Request;
pub const prefix = "/admin/messages/";

/// The language the admin speaks to a session: its code, its catalogue as the renders take
/// it, and the address of its script. English, or a language no plugin brings any more,
/// has neither.
pub const Language = struct {
    locale: []const u8 = "en",
    translator: ?*const runtime.Translator = null,
    messages: []const u8 = "",
    /// The catalogue's script, for the render's script engine.
    script: []const u8 = "",
    /// The person never chose and the admin speaks more than English: welcome them first.
    welcome: bool = false,
};

/// The person's language, for a session signed in; English for one that is not.
pub fn of(session: *Session) Language {
    std.debug.assert(session.ctx.now_ms > 0);

    if (!session.signed_in()) {
        return .{};
    }

    return chosen(session) catch .{};
}

fn chosen(session: *Session) admin.Error!Language {
    std.debug.assert(session.signed_in());

    const shown = registry.SDK.dispatch(&session.ctx, language_operations.Language, .{}) catch {
        return .{};
    };
    const languages = session.project.languages orelse return .{};

    languages.apply(shown.chosen_translations) catch |err| {
        std.log.err("languages: the chosen translations: {t}", .{err});
    };

    var found = try in(session, shown.shown);

    found.welcome = !shown.answered;

    return found;
}

/// The admin speaking `locale`: its catalogue, the script's address; English when no
/// plugin brings it.
pub fn in(session: *Session, locale: []const u8) admin.Error!Language {
    std.debug.assert(locale.len > 0);

    const languages = session.project.languages orelse return .{};
    const language = languages.find(locale) orelse return .{};
    const catalog = &language.catalog;
    const translator = try session.arena.create(runtime.Translator);

    translator.* = .{
        .context = catalog,
        .lookup = server_languages.lookup,
    };

    return .{
        .locale = locale,
        .translator = translator,
        .messages = try std.fmt.allocPrint(session.arena, "{s}{s}{s}.js?v={s}-{d}", .{
            session.project.admin_path(),
            prefix,
            locale,
            @import("../../publr.zig").version,
            catalog.messages(),
        }),
        .script = language.script,
    };
}

/// The session's language on the page's request: `<html lang>`, the renders' catalogue, the
/// browser's script.
pub fn apply(session: *const Session, request: *Request) void {
    std.debug.assert(session.language.locale.len > 0);

    request.admin.locale = session.language.locale;
    request.admin.messages = session.language.messages;
    request.publr_translations = session.language.translator;
    request.publr_catalogue = session.language.script;
}

/// The account menu's languages: the site's default, then each language the admin speaks,
/// the person's own choice ticked; null while no plugin translates the admin.
pub fn menu_of(session: *Session) admin.Error!?admin.render.Node {
    std.debug.assert(session.signed_in());

    const shown = registry.SDK.dispatch(&session.ctx, language_operations.Language, .{}) catch {
        return null;
    };

    if (shown.choices.len < 2) {
        return null;
    }

    const Choice = admin.views.LanguageMenu.ChoicesItem;
    const items = try session.arena.alloc(Choice, shown.choices.len + 1);
    const site_label = label_of(shown.choices, if (shown.site.len > 0) shown.site else "en");

    items[0] = .{
        .locale = "",
        .label = try session.translated_with("Site default ({language})", &.{.{
            .name = "language",
            .value = site_label,
        }}),
        .current = shown.chosen.len == 0,
    };

    for (shown.choices, items[1..]) |choice, *item| {
        item.* = .{
            .locale = choice.locale,
            .label = choice.label,
            .current = std.mem.eql(u8, choice.locale, shown.chosen),
        };
    }

    return try admin.render.view(session.arena, admin.views.LanguageMenu, .{
        .back = session.request.path(),
        .choices = items,
    });
}

fn label_of(choices: []const language_operations.Choice, locale: []const u8) []const u8 {
    std.debug.assert(locale.len > 0);

    for (choices) |choice| {
        if (std.mem.eql(u8, choice.locale, locale)) {
            return choice.label;
        }
    }

    return locale;
}

/// `POST /admin/language`: the person's choice saved, the page they were on again.
pub fn choose(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, "/admin") orelse return;
    const session = &post.session;
    const language = post.form.text("language") orelse "";
    const back = post.form.text("back") orelse "/admin";
    const local = back.len > 0 and back[0] == '/' and !std.mem.startsWith(u8, back, "//");

    _ = registry.SDK.dispatch(&session.ctx, language_operations.SetLanguage, .{
        .language = language,
    }) catch |err| return admin.fail(session, err, "/admin");

    try response.redirect(.see_other, if (local) back else "/admin");
}

/// A message in the session's language, `{name}` filled from `values`.
pub fn text(
    session: *const Session,
    context: []const u8,
    id: []const u8,
    values: []const runtime.Placeholder,
) admin.Error![]const u8 {
    std.debug.assert(id.len > 0);

    return runtime.translate(session.arena, session.language.translator, .{
        .context = context,
        .id = id,
        .values = values,
    });
}

/// A message for `count` of something, in the session's language.
pub fn counted(
    session: *const Session,
    one: []const u8,
    other: []const u8,
    count: u64,
    values: []const runtime.Placeholder,
) admin.Error![]const u8 {
    std.debug.assert(one.len > 0 and other.len > 0);

    return runtime.translate(session.arena, session.language.translator, .{
        .id = one,
        .plural = other,
        .count = @floatFromInt(count),
        .values = values,
    });
}

/// `/admin/messages/<locale>.js`: the catalogue for the browser, kept a year (its address
/// carries its version).
pub fn messages(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(std.mem.startsWith(u8, request.path(), prefix));
    std.debug.assert(ctx.user_data != null);

    const name = request.path()[prefix.len..];
    const locale = if (std.mem.endsWith(u8, name, ".js")) name[0 .. name.len - 3] else name;
    const project = @import("../../server/project.zig").Project.of(ctx);
    const languages = project.languages orelse return response.text(.not_found, "Not Found");
    const language = languages.find(locale) orelse return response.text(.not_found, "Not Found");

    try response.set_body(.ok, "text/javascript; charset=utf-8", language.script);
    try response.set_header("Cache-Control", "public, max-age=31536000, immutable");
}
