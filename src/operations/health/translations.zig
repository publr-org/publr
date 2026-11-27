//! Site Health's second section: messages the installed translations of one language render
//! differently. The words' owner's own translation is shown until someone picks another;
//! every disagreement is listed, with each plugin's version, until one is picked.
const std = @import("std");
const public = @import("../../publr/operations/health/translations.zig");
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

pub const Candidate = public.Candidate;
pub const Disagreement = public.Disagreement;

pub const Translations = struct {
    pub const shape = public.Translations;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        return listed(ctx, try position_of(in.after));
    }
};

/// A place in a list the running server holds in memory, in the order it holds it: what a
/// page of it answers in `next` (`200`), read back from `after`.
pub fn position_of(after: []const u8) Error!u32 {
    if (after.len == 0) {
        return 0;
    }

    if (after.len > 10) {
        return error.Invalid;
    }

    std.debug.assert(after.len > 0 and after.len <= 10);

    return std.fmt.parseInt(u32, after, 10) catch error.Invalid;
}

/// The page of disagreements from `start`, and how many over all are not picked yet: also
/// what Site Health's count adds.
pub fn listed(ctx: *Ctx, start: u32) Error!Translations.Out {
    std.debug.assert(registry.translations.len <= 1024);
    std.debug.assert(ctx.now_ms >= 0);

    const kept = try kept_of(ctx);
    const view = ctx.translations orelse return .{
        .disagreements = &.{},
        .open = 0,
    };
    const page_max = sdk.operation.page_limit_max;
    var out: std.ArrayList(Disagreement) = .empty;
    var open: u32 = 0;
    var place: u32 = 0;

    for (view.disagreements(view.context)) |language| {
        for (language.conflicts) |conflict| {
            const chosen = chosen_of(kept, language.locale, conflict.context, conflict.id);
            const shown = place >= start and out.items.len < page_max;

            open += @intFromBool(chosen.len == 0);
            place += 1;

            if (!shown) {
                continue;
            }

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

    const shown_end = start + @as(u32, @intCast(out.items.len));

    return .{
        .disagreements = out.items,
        .open = open,
        .next = if (shown_end < place)
            std.fmt.allocPrint(ctx.arena, "{d}", .{shown_end}) catch return error.OutOfMemory
        else
            "",
    };
}

pub const MissingTranslations = struct {
    pub const shape = public.MissingTranslations;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.ChooseTranslation;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or (in.provider.len > 0 and !provides(ctx, in.provider, in.locale))) {
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

/// Whether `provider` is one of the plugins translating the message in `locale`: compiled
/// in or installed, as the server's catalogues hold them, the compiled-in ones where none do.
fn provides(ctx: *const Ctx, provider: []const u8, locale: []const u8) bool {
    std.debug.assert(provider.len > 0);

    const view = ctx.translations orelse return compiled_provides(provider, locale);

    for (view.disagreements(view.context)) |language| {
        if (!std.mem.eql(u8, language.locale, locale)) {
            continue;
        }

        for (language.conflicts) |conflict| {
            for (conflict.candidates) |candidate| {
                if (std.mem.eql(u8, candidate.provider, provider)) {
                    return true;
                }
            }
        }
    }

    return false;
}

fn compiled_provides(provider: []const u8, locale: []const u8) bool {
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
