//! Site Health's second section: messages the installed translations of one language render
//! differently. The words' owner's own translation is shown until someone picks another;
//! every disagreement is listed, with each plugin's version, until one is picked.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const languages = @import("../../server/languages.zig");
const language_operations = @import("../user/language.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Kept = languages.Kept;

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

/// One language over one domain's messages.
pub const Covered = struct {
    locale: []const u8,
    label: []const u8,
    /// `publr` for the core's words, a plugin's name for its own.
    domain: []const u8,
    translated: u32,
    total: u32,
    /// The plugins bringing this language's translations of the domain.
    providers: []const []const u8,
};

pub const Translations = struct {
    pub const name = "health.translations";
    pub const description = "List the messages installed translations render differently";
    pub const details =
        \\Administrators only. For each language, each message two or more plugins translate
        \\differently, with every plugin's version; `chosen` names the one picked with
        \\`health choose_translation`, empty while the first-party one shows. `open` counts
        \\the ones not picked yet.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        disagreements: []const Disagreement,
        open: u32,
        coverage: []const Covered = &.{},
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .disagreements = &.{},
        .open = 0,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .disagreements = "Each message with its language, every plugin's version, the one picked",
        .open = "How many are not picked yet",
        .coverage = "Each language over each domain's messages: how many it translates, by whom",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        return listed(ctx);
    }
};

/// Every disagreement, and how many are not picked yet: also what Site Health's count adds.
pub fn listed(ctx: *Ctx) Error!Translations.Out {
    std.debug.assert(registry.translations.len <= 1024);
    std.debug.assert(ctx.now_ms >= 0);

    const kept = try kept_of(ctx);
    const view = ctx.translations orelse return .{
        .disagreements = &.{},
        .open = 0,
    };
    var out: std.ArrayList(Disagreement) = .empty;
    var open: u32 = 0;

    for (view.disagreements(view.context)) |language| {
        for (language.conflicts) |conflict| {
            const chosen = chosen_of(kept, language.locale, conflict.context, conflict.id);

            open += @intFromBool(chosen.len == 0);
            out.append(ctx.arena, .{
                .locale = language.locale,
                .label = language.label,
                .context = conflict.context,
                .id = conflict.id,
                .candidates = try candidates_of(ctx, conflict.candidates),
                .chosen = chosen,
            }) catch return error.OutOfMemory;
        }
    }

    return .{
        .disagreements = out.items,
        .open = open,
        .coverage = try covered_of(ctx, view),
    };
}

fn covered_of(ctx: *Ctx, view: sdk.context.Translations) Error![]const Covered {
    std.debug.assert(ctx.now_ms >= 0);

    const all = view.coverage(view.context);
    const out = ctx.arena.alloc(Covered, all.len) catch return error.OutOfMemory;

    for (all, out) |coverage, *covered| {
        covered.* = .{
            .locale = coverage.locale,
            .label = coverage.label,
            .domain = coverage.domain,
            .translated = coverage.translated,
            .total = coverage.total,
            .providers = coverage.providers,
        };
    }

    return out;
}

pub const MissingTranslations = struct {
    pub const name = "health.missing_translations";
    pub const description = "The messages a language does not translate yet, as a PO template";
    pub const details =
        \\Administrators only. For one language and one domain (`publr` for the core, a
        \\plugin's name for its words), every message no installed plugin translates, as a
        \\gettext template to fill in a PO editor and ship as a plugin of translations.
    ;
    pub const kind: sdk.operation.Kind = .read;
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
        .domain = "ai_usage",
    };
    pub const example_out: Out = .{
        .template = "msgid \"AI usage\"\nmsgstr \"\"\n",
        .missing = 1,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .locale = "The language (`pl`)",
        .domain = "Whose words: `publr`, or a plugin's name",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .template = "The missing messages as a `.pot` file",
        .missing = "How many there are",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const view = ctx.translations orelse return error.NotFound;

        for (view.coverage(view.context)) |coverage| {
            const same = std.mem.eql(u8, coverage.locale, in.locale) and
                std.mem.eql(u8, coverage.domain, in.domain);

            if (same) {
                return .{
                    .template = try template_of(ctx, coverage),
                    .missing = @intCast(coverage.missing.len),
                };
            }
        }

        return error.NotFound;
    }
};

/// The missing messages as a gettext template, its header naming the language and domain.
fn template_of(ctx: *Ctx, coverage: sdk.context.Coverage) Error![]const u8 {
    std.debug.assert(coverage.locale.len > 0);

    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    const writer = &out.writer;

    writer.print("# {s}: the messages of {s} not translated into {s} yet.\n" ++
        "msgid \"\"\nmsgstr \"\"\n\"Language: {s}\\n\"\n" ++
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n\n", .{
        coverage.label,
        coverage.domain,
        coverage.locale,
        coverage.locale,
    }) catch return error.OutOfMemory;

    for (coverage.missing) |message| {
        if (message.context.len > 0) {
            try quoted(writer, "msgctxt", message.context);
        }

        try quoted(writer, "msgid", message.id);
        writer.writeAll("msgstr \"\"\n\n") catch return error.OutOfMemory;
    }

    return out.written();
}

fn quoted(writer: *std.Io.Writer, keyword: []const u8, text: []const u8) Error!void {
    std.debug.assert(keyword.len > 0);

    writer.print("{s} \"", .{keyword}) catch return error.OutOfMemory;

    for (text) |char| {
        const written = switch (char) {
            '"' => writer.writeAll("\\\""),
            '\\' => writer.writeAll("\\\\"),
            '\n' => writer.writeAll("\\n"),
            else => writer.writeByte(char),
        };

        written catch return error.OutOfMemory;
    }

    writer.writeAll("\"\n") catch return error.OutOfMemory;
}

fn candidates_of(ctx: *Ctx, found: []const model.i18n.conflicts.Candidate) Error![]const Candidate {
    std.debug.assert(found.len >= 2);

    const out = ctx.arena.alloc(Candidate, found.len) catch return error.OutOfMemory;

    for (found, out) |candidate, *shown| {
        shown.* = .{
            .provider = candidate.provider,
            .first_party = candidate.first_party,
            .text = std.mem.join(ctx.arena, " / ", candidate.forms) catch return error.OutOfMemory,
        };
    }

    return out;
}

fn kept_of(ctx: *Ctx) Error![]Kept {
    std.debug.assert(ctx.now_ms >= 0);

    const key = language_operations.choices_key;
    const stored = try store.settings.get(ctx.db, ctx.arena, key) orelse "[]";
    const parsed = std.json.parseFromSliceLeaky([]Kept, ctx.arena, stored, .{
        .ignore_unknown_fields = true,
    }) catch return &.{};

    return parsed;
}

fn chosen_of(
    kept: []const Kept,
    locale: []const u8,
    context: []const u8,
    id: []const u8,
) []const u8 {
    std.debug.assert(id.len > 0);

    for (kept) |choice| {
        const same = std.mem.eql(u8, choice.locale, locale) and
            std.mem.eql(u8, choice.context, context) and std.mem.eql(u8, choice.id, id);

        if (same) {
            return choice.provider;
        }
    }

    return "";
}

pub const ChooseTranslation = struct {
    pub const name = "health.choose_translation";
    pub const description = "Pick which plugin's translation of a message shows";
    pub const details =
        \\Administrators only. One of the plugins `health translations` lists for the
        \\message; an empty `provider` goes back to the first-party one. The admin shows the
        \\pick from the next page on.
    ;
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .locale = "The language (`pl`)",
        .context = "The message's context, when it has one",
        .id = "The message as written in English",
        .provider = "The plugin whose translation shows; empty for the first-party one",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .chosen = "The plugin picked",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or (in.provider.len > 0 and !provides(in.provider, in.locale))) {
            return error.Invalid;
        }

        var kept: std.ArrayList(Kept) = .empty;

        for (try kept_of(ctx)) |choice| {
            const same = std.mem.eql(u8, choice.locale, in.locale) and
                std.mem.eql(u8, choice.context, in.context) and std.mem.eql(u8, choice.id, in.id);

            if (!same) {
                kept.append(ctx.arena, choice) catch return error.OutOfMemory;
            }
        }

        if (in.provider.len > 0) {
            kept.append(ctx.arena, .{
                .locale = in.locale,
                .context = in.context,
                .id = in.id,
                .provider = in.provider,
            }) catch return error.OutOfMemory;
        }

        const text = std.json.Stringify.valueAlloc(ctx.arena, kept.items, .{}) catch {
            return error.OutOfMemory;
        };

        try store.settings.set(ctx.db, language_operations.choices_key, text, ctx.now_ms);

        return .{
            .chosen = in.provider,
        };
    }
};

fn provides(provider: []const u8, locale: []const u8) bool {
    std.debug.assert(provider.len > 0);

    for (registry.translations) |owned| {
        const same = std.mem.eql(u8, owned.plugin, provider) and
            std.mem.eql(u8, owned.translation.locale, locale);

        if (same) {
            return true;
        }
    }

    return false;
}
