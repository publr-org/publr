//! Site Health's second section: messages the installed translations of one language render
//! differently. The words' owner's own translation is shown until someone picks another;
//! every disagreement is listed, with each plugin's version, until one is picked.
const operation = @import("../../operation.zig");

pub const Candidate = struct {
    provider: []const u8,
    first_party: bool,
    /// The translation; a plural's forms one after another, ` / ` between them.
    text: []const u8,
};

pub const Disagreement = struct {
    locale: []const u8,
    label: []const u8,
    context: []const u8,
    id: []const u8,
    candidates: []const Candidate,
    /// The plugin picked; empty while none is, and the first-party one is shown.
    chosen: []const u8,
};

pub const Translations = struct {
    pub const name = "health.translations";
    pub const description = "List the messages installed translations render differently";
    pub const details =
        \\Administrators only. For each language, each message two or more plugins translate
        \\differently, with every plugin's version; `chosen` names the one picked with
        \\`health choose_translation`, empty while the first-party one shows. `open` counts
        \\the ones not picked yet. A page of 200 at a time, by language: `next` continues it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        after: []const u8 = "",
    };
    pub const Out = struct {
        disagreements: []const Disagreement,
        open: u32,
        next: []const u8 = "",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .disagreements = &.{},
        .open = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .after = "The page after this one: the `next` the last page answered",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .disagreements = "Each message with its language, every plugin's version, the one picked",
        .open = "How many are not picked yet, over every page",
        .next = "The next page's `after`; empty after the last",
    };
};

pub const MissingTranslations = struct {
    pub const name = "health.missing_translations";
    pub const description = "The messages a language does not translate yet, as a PO template";
    pub const details =
        \\Administrators only. For one language and one domain (`publr` for the core, a
        \\plugin's name for its words), every message no installed plugin translates, as a
        \\gettext template to fill in a PO editor and ship as a plugin of translations.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        locale: []const u8,
        domain: []const u8,
    };
    pub const Out = struct {
        template: []const u8,
        missing: u32,
    };
    pub const example: In = .{
        .locale = "pl",
        .domain = "publr",
    };
    pub const example_out: Out = .{
        .template = "msgid \"AI usage\"\nmsgstr \"\"\n",
        .missing = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .locale = "The language (`pl`)",
        .domain = "Whose words: `publr`, or a plugin's name",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .template = "The missing messages as a `.pot` file",
        .missing = "How many there are",
    };
};

pub const ChooseTranslation = struct {
    pub const name = "health.choose_translation";
    pub const description = "Pick which plugin's translation of a message shows";
    pub const details =
        \\Administrators only. One of the plugins `health translations` lists for the
        \\message; an empty `provider` goes back to the first-party one. The admin shows the
        \\pick from the next page on.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        locale: []const u8,
        context: []const u8 = "",
        id: []const u8,
        provider: []const u8,
    };
    pub const Out = struct {
        chosen: []const u8,
    };
    pub const example: In = .{
        .locale = "pl",
        .id = "Save",
        .provider = "language_pl",
    };
    pub const example_out: Out = .{
        .chosen = "language_pl",
    };
    pub const field_docs: operation.Docs(In) = .{
        .locale = "The language (`pl`)",
        .context = "The message's context, when it has one",
        .id = "The message as written in English",
        .provider = "The plugin whose translation shows; empty for the first-party one",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .chosen = "The plugin picked",
    };
};
