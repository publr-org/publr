//! The language the admin speaks to a person: their own choice, else the site's, else
//! English. The languages are the ones plugins bring PO files for, and English.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

const site_key = "admin_language";
/// Site Health's choices between translations that disagree, as JSON.
pub const choices_key = "translation_choices";
const person_prefix = "admin_language:";

pub const Choice = struct {
    locale: []const u8,
    label: []const u8,
};

/// English, then every language a plugin translates the admin into, compiled in or
/// installed, each once. Where no server built the catalogues (the browser), the
/// compiled-in ones.
pub fn choices(ctx: *const Ctx) Error![]const Choice {
    std.debug.assert(registry.translations.len <= 1024);

    const arena = ctx.arena;
    var list: std.ArrayList(Choice) = .empty;

    list.append(arena, .{
        .locale = "en",
        .label = "English",
    }) catch return error.OutOfMemory;

    if (ctx.translations) |translations| {
        for (try translations.spoken(translations.context, arena)) |language| {
            if (!known(list.items, language.locale)) {
                list.append(arena, .{
                    .locale = language.locale,
                    .label = language.label,
                }) catch return error.OutOfMemory;
            }
        }

        return list.items;
    }

    for (registry.translations) |owned| {
        const translation = owned.translation;

        if (known(list.items, translation.locale)) {
            continue;
        }

        list.append(arena, .{
            .locale = translation.locale,
            .label = translation.label,
        }) catch return error.OutOfMemory;
    }

    return list.items;
}

fn known(list: []const Choice, locale: []const u8) bool {
    std.debug.assert(locale.len > 0);

    for (list) |choice| {
        if (std.mem.eql(u8, choice.locale, locale)) {
            return true;
        }
    }

    return false;
}

pub const Language = struct {
    pub const name = "user.language";
    pub const description = "The language the admin speaks to you, and the ones it can";
    pub const details =
        \\Any signed-in account, about itself: `chosen` is its own choice (empty: the
        \\site's), `site` the site's default, `shown` the one in use, and `choices` English
        \\and every language a plugin translates the admin into.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    /// Open, but about the account asking: its example names one.
    pub const example_signed_in = true;
    pub const In = struct {};
    pub const Out = struct {
        chosen: []const u8,
        site: []const u8,
        shown: []const u8,
        choices: []const Choice,
        /// Whether the person ever chose (the site's default counts): the admin welcomes
        /// someone who has not.
        answered: bool = true,
        /// Site Health's choices between translations that disagree, as stored.
        chosen_translations: []const u8 = "",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .chosen = "",
        .site = "",
        .shown = "en",
        .choices = &.{.{
            .locale = "en",
            .label = "English",
        }},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .chosen = "Your own choice; empty for the site's",
        .site = "The site's default for everyone who chose none",
        .shown = "The language the admin speaks to you",
        .choices = "Each language the admin speaks: `locale` and its own name",
        .chosen_translations = "The translations picked where several disagree, as JSON",
        .answered = "Whether you ever chose; the admin asks once at the first sign-in",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const user = ctx.caller.user_id() orelse return error.Denied;
        const all = try choices(ctx);
        const site = try stored(ctx, site_key, all);
        const key = std.mem.concat(ctx.arena, u8, &.{ person_prefix, user }) catch {
            return error.OutOfMemory;
        };
        const chosen = try stored(ctx, key, all);
        const answered = try store.settings.get(ctx.db, ctx.arena, key) != null;

        return .{
            .answered = answered,
            .chosen = chosen,
            .site = site,
            .shown = if (chosen.len > 0) chosen else if (site.len > 0) site else "en",
            .choices = all,
            .chosen_translations = try store.settings.get(ctx.db, ctx.arena, choices_key) orelse "",
        };
    }
};

/// The language a person reads, wherever they call from (the admin, REST, the command
/// line): their own choice, else the site's; empty for English, and for nobody signed in.
pub fn speaks(ctx: *Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    const user = ctx.caller.user_id() orelse return "";

    return person_speaks(ctx, user);
}

/// The language the account `user` reads: their own choice, else the site's; empty for
/// English (`ctx.locale(person)`).
pub fn person_speaks(ctx: *Ctx, user: []const u8) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(user.len > 0);

    const all = try choices(ctx);
    const key = std.mem.concat(ctx.arena, u8, &.{ person_prefix, user }) catch {
        return error.OutOfMemory;
    };
    const chosen = try stored(ctx, key, all);

    return if (chosen.len > 0) chosen else stored(ctx, site_key, all);
}

/// The site's language, where nobody is asked (queued work queued with none): empty for
/// English.
pub fn site_speaks(ctx: *Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    return stored(ctx, site_key, try choices(ctx));
}

/// What a key holds, while a plugin still brings the language; empty otherwise.
fn stored(ctx: *Ctx, key: []const u8, all: []const Choice) Error![]const u8 {
    std.debug.assert(key.len > 0);

    const value = try store.settings.get(ctx.db, ctx.arena, key) orelse return "";

    // Empty is a choice too: the site's default.
    if (value.len == 0) {
        return "";
    }

    return if (known(all, value)) value else "";
}

pub const SetLanguage = struct {
    pub const name = "user.set_language";
    pub const description = "Choose the language the admin speaks to you";
    pub const details =
        \\Any signed-in account, for itself: one of `user language`'s choices, or empty for
        \\the site's.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    /// Open, but about the account asking: its example names one.
    pub const example_signed_in = true;
    pub const In = struct {
        language: []const u8,
    };
    pub const Out = struct {
        language: []const u8,
    };
    pub const example: In = .{
        .language = "en",
    };
    pub const example_out: Out = .{
        .language = "en",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .language = "A language's code (`pl`), or empty for the site's",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .language = "Your choice now",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const user = ctx.caller.user_id() orelse return error.Denied;
        const key = std.mem.concat(ctx.arena, u8, &.{ person_prefix, user }) catch {
            return error.OutOfMemory;
        };

        try save(ctx, key, in.language);

        return .{
            .language = in.language,
        };
    }
};

pub const SetSiteLanguage = struct {
    pub const name = "project.set_admin_language";
    pub const description = "Choose the language the admin speaks to everyone who chose none";
    pub const details =
        \\Administrators only. One of `user language`'s choices, or empty for English.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        language: []const u8,
    };
    pub const Out = struct {
        language: []const u8,
    };
    pub const example: In = .{
        .language = "en",
    };
    pub const example_out: Out = .{
        .language = "en",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .language = "A language's code (`pl`), or empty for English",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .language = "The site's default now",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        try save(ctx, site_key, in.language);

        return .{
            .language = in.language,
        };
    }
};

/// Whether `language` is one the admin speaks; empty is: the site's own, English.
pub fn valid(ctx: *Ctx, language: []const u8) Error!bool {
    std.debug.assert(language.len <= 64 << 10);

    return language.len == 0 or known(try choices(ctx), language);
}

/// A fresh site's language, chosen as it is set up: the site's default, and its first
/// account's own choice, so that account is never asked. Empty keeps English.
pub fn set_first(ctx: *Ctx, user_id: []const u8, language: []const u8) Error!void {
    std.debug.assert(user_id.len > 0);

    if (language.len > 0) {
        try save(ctx, site_key, language);
    }

    const key = std.mem.concat(ctx.arena, u8, &.{ person_prefix, user_id }) catch {
        return error.OutOfMemory;
    };

    try save(ctx, key, language);
}

fn save(ctx: *Ctx, key: []const u8, language: []const u8) Error!void {
    std.debug.assert(key.len > 0);

    if (language.len > 0 and !known(try choices(ctx), language)) {
        return refused(ctx, "language");
    }

    try store.settings.set(ctx.db, key, language, ctx.now_ms);
}

/// `language` refused on `field`: which languages the admin speaks, and that this is not the
/// site's content language, which the languages plugin keeps.
pub fn refused(ctx: *Ctx, field: []const u8) Error {
    std.debug.assert(field.len > 0);

    var spoken: std.Io.Writer.Allocating = .init(ctx.arena);

    for (try choices(ctx), 0..) |choice, index| {
        const separator: []const u8 = if (index == 0) "" else ", ";

        spoken.writer.print("{s}{s} ({s})", .{ separator, choice.locale, choice.label }) catch {
            return error.OutOfMemory;
        };
    }

    const message = std.fmt.allocPrint(ctx.arena, "The admin speaks {s}. This is the admin's " ++
        "language, not the site's: a site's languages are the languages plugin's " ++
        "(`languages save`)", .{spoken.written()}) catch return error.OutOfMemory;
    const problems = ctx.arena.alloc(sdk.operation.Problem, 1) catch return error.OutOfMemory;

    problems[0] = .{
        .field = field,
        .message = message,
    };

    return ctx.refuse(problems);
}
