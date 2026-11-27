//! The language the admin speaks to a person: their own choice, else the site's, else
//! English. The languages are the ones plugins bring PO files for, and English.
const operation = @import("../../operation.zig");

pub const Choice = struct {
    locale: []const u8,
    label: []const u8,
};

pub const Language = struct {
    pub const name = "user.language";
    pub const description = "The language the admin speaks to you, and the ones it can";
    pub const details =
        \\Any signed-in account, about itself: `chosen` is its own choice (empty: the
        \\site's), `site` the site's default, `shown` the one in use, and `choices` English
        \\and every language a plugin translates the admin into.
    ;
    pub const kind: operation.Kind = .read;
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
        chosen_translations: ?operation.Json = null,
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
    pub const field_docs: operation.Docs(In) = .{};
    pub const output_docs: operation.Docs(Out) = .{
        .chosen = "Your own choice; empty for the site's",
        .site = "The site's default for everyone who chose none",
        .shown = "The language the admin speaks to you",
        .choices = "Each language the admin speaks: `locale` and its own name",
        .chosen_translations = "The translations picked where several disagree; null for none",
        .answered = "Whether you ever chose; until then the site's default, else English",
    };
};

pub const SetLanguage = struct {
    pub const name = "user.set_language";
    pub const description = "Choose the language the admin speaks to you";
    pub const details =
        \\Any signed-in account, for itself: one of `user language`'s choices, or empty for
        \\the site's.
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .language = "A language's code (`pl`), or empty for the site's",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .language = "Your choice now",
    };
};

pub const SetSiteLanguage = struct {
    pub const name = "project.set_admin_language";
    pub const description = "Choose the language the admin speaks to everyone who chose none";
    pub const details =
        \\Administrators only. One of `user language`'s choices, or empty for English.
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .language = "A language's code (`pl`), or empty for English",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .language = "The site's default now",
    };
};
