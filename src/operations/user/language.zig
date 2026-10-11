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

/// English, then every language a plugin translates the admin into, each once.
pub fn choices(arena: std.mem.Allocator) Error![]const Choice {
    std.debug.assert(registry.translations.len <= 1024);

    var list: std.ArrayList(Choice) = .empty;

    list.append(arena, .{
        .locale = "en",
        .label = "English",
    }) catch return error.OutOfMemory;

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
        .site = "pl",
        .shown = "pl",
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
        const all = try choices(ctx.arena);
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
    pub const In = struct {
        language: []const u8,
    };
    pub const Out = struct {
        language: []const u8,
    };
    pub const example: In = .{
        .language = "pl",
    };
    pub const example_out: Out = .{
        .language = "pl",
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
        .language = "pl",
    };
    pub const example_out: Out = .{
        .language = "pl",
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

fn save(ctx: *Ctx, key: []const u8, language: []const u8) Error!void {
    std.debug.assert(key.len > 0);

    if (language.len > 0 and !known(try choices(ctx.arena), language)) {
        return error.Invalid;
    }

    try store.settings.set(ctx.db, key, language, ctx.now_ms);
}
