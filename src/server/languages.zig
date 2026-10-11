//! The admin's languages: one catalogue per language the plugins bring PO files for, built
//! once when the server starts from every file in that language. English is the source text
//! and needs none.
const std = @import("std");
const model = @import("../model.zig");
const registry = @import("registry.zig");

const Catalog = model.i18n.Catalog;
const Source = model.i18n.catalog.Source;
const Choice = model.i18n.catalog.Choice;
const OwnedTranslation = @import("../sdk/plugin.zig").OwnedTranslation;

/// A choice as Site Health keeps it, in the language it is for.
pub const Kept = struct {
    locale: []const u8,
    context: []const u8 = "",
    id: []const u8,
    provider: []const u8,
};

pub const languages_max: u32 = 64;

pub const Language = struct {
    locale: []const u8,
    label: []const u8,
    catalog: Catalog,
    /// The catalogue as the browser and the render's script engine read it:
    /// `globalThis.__publr_messages = { rule, messages }`.
    script: []const u8,
};

const LanguageDisagreements = @import("../sdk/context.zig").LanguageDisagreements;
const Coverage = @import("../sdk/context.zig").Coverage;
const coverage_of = @import("languages/coverage.zig").of;

pub const Languages = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    list: []const Language,
    /// Each language's messages its translations render differently.
    disagreements: []const LanguageDisagreements = &.{},
    /// Each language over each domain's messages.
    coverage: []const Coverage = &.{},
    /// The choices the catalogues were built with, as stored; rebuilt when they change.
    applied: []const u8 = "",

    /// The plugins' PO files, by language. A file the language's plural rule cannot take
    /// stops the server, naming the language: its translations would land on wrong counts.
    pub fn init(languages: *Languages, gpa: std.mem.Allocator) !void {
        std.debug.assert(registry.translations.len <= 1024);

        languages.gpa = gpa;
        languages.applied = "";
        languages.arena = .init(gpa);
        errdefer languages.arena.deinit();

        languages.list = try build(languages.arena.allocator(), registry.translations, &.{});
        const arena = languages.arena.allocator();

        languages.disagreements = try disagreements_of(arena, registry.translations);
        languages.coverage = try coverage_of(languages.arena.allocator(), languages.list);
    }

    /// The view operations read the disagreements through (`Ctx.translations`).
    pub fn view(languages: *const Languages) @import("../sdk/context.zig").Translations {
        std.debug.assert(languages.list.len <= languages_max);

        return .{
            .context = languages,
            .disagreements = read_disagreements,
            .coverage = read_coverage,
        };
    }

    pub fn deinit(languages: *Languages) void {
        std.debug.assert(languages.list.len <= languages_max);

        languages.arena.deinit();
        languages.* = undefined;
    }

    /// The catalogues built again with `stored` choices (Site Health's, as JSON), when they
    /// differ from the ones applied. A choice that no longer parses is left out.
    pub fn apply(languages: *Languages, stored: []const u8) !void {
        std.debug.assert(stored.len <= 16 << 20);

        if (std.mem.eql(u8, stored, languages.applied)) {
            return;
        }

        var fresh: std.heap.ArenaAllocator = .init(languages.gpa);
        errdefer fresh.deinit();

        const arena = fresh.allocator();
        const kept = std.json.parseFromSliceLeaky([]const Kept, arena, stored, .{
            .ignore_unknown_fields = true,
        }) catch &.{};
        const list = try build(arena, registry.translations, kept);

        languages.disagreements = try disagreements_of(arena, registry.translations);
        languages.coverage = try coverage_of(arena, list);
        languages.arena.deinit();
        languages.arena = fresh;
        languages.list = list;
        languages.applied = try arena.dupe(u8, stored);
    }

    /// The language, null for English and any language no plugin brings.
    pub fn find(languages: *const Languages, locale: []const u8) ?*const Language {
        std.debug.assert(languages.list.len <= languages_max);

        for (languages.list) |*language| {
            if (std.mem.eql(u8, language.locale, locale)) {
                return language;
            }
        }

        return null;
    }
};

fn build(
    arena: std.mem.Allocator,
    translations: []const OwnedTranslation,
    kept: []const Kept,
) ![]const Language {
    std.debug.assert(translations.len <= 1024);

    var list: std.ArrayList(Language) = .empty;

    for (translations, 0..) |owned, index| {
        const translation = owned.translation;

        if (seen(translations[0..index], translation.locale)) {
            continue;
        }

        const sources = try sources_of(arena, translations[index..], translation.locale);
        const choices = try choices_in(arena, kept, translation.locale);
        const catalog = Catalog.init(arena, translation.locale, sources, choices) catch |err| {
            std.log.err("languages: the {s} translations: {t}", .{ translation.locale, err });

            return err;
        };

        try list.append(arena, .{
            .locale = translation.locale,
            .label = translation.label,
            .catalog = catalog,
            .script = try script_of(arena, &catalog),
        });
    }

    if (list.items.len > languages_max) {
        return error.TooManyLanguages;
    }

    return list.items;
}

/// `globalThis.__publr_messages = { rule, messages }`: each message under its key (its
/// context, `\u0004`, then its text, or its text alone), as its forms.
fn script_of(arena: std.mem.Allocator, catalog: *const Catalog) ![]const u8 {
    std.debug.assert(catalog.locale.len > 0);

    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    var stringify: std.json.Stringify = .{
        .writer = writer,
    };

    try writer.print("globalThis.__publr_messages={{\"rule\":\"{t}\",\"messages\":", .{
        catalog.rule,
    });
    try stringify.beginObject();

    var entries = catalog.map.iterator();

    while (entries.next()) |entry| {
        try stringify.objectField(entry.key_ptr.*);
        try stringify.write(entry.value_ptr.*);
    }

    try stringify.endObject();
    try writer.writeAll("};\n");

    return out.written();
}

fn read_coverage(context: *const anyopaque) []const Coverage {
    const languages: *const Languages = @ptrCast(@alignCast(context));

    std.debug.assert(languages.list.len <= languages_max);

    return languages.coverage;
}

fn read_disagreements(context: *const anyopaque) []const LanguageDisagreements {
    const languages: *const Languages = @ptrCast(@alignCast(context));

    std.debug.assert(languages.list.len <= languages_max);

    return languages.disagreements;
}

/// Each language's disagreements between the translations installed for it.
fn disagreements_of(
    arena: std.mem.Allocator,
    translations: []const OwnedTranslation,
) ![]const LanguageDisagreements {
    std.debug.assert(translations.len <= 1024);

    var out: std.ArrayList(LanguageDisagreements) = .empty;

    for (translations, 0..) |owned, index| {
        if (seen(translations[0..index], owned.translation.locale)) {
            continue;
        }

        const sources = try sources_of(arena, translations[index..], owned.translation.locale);

        try out.append(arena, .{
            .locale = owned.translation.locale,
            .label = owned.translation.label,
            .conflicts = try model.i18n.conflicts.of(arena, sources),
        });
    }

    return out.items;
}

/// Every PO file in `locale`, each with who brings it and whether it is first-party.
pub fn sources_of(
    arena: std.mem.Allocator,
    translations: []const OwnedTranslation,
    locale: []const u8,
) ![]const Source {
    std.debug.assert(locale.len > 0);

    var sources: std.ArrayList(Source) = .empty;

    for (translations) |owned| {
        if (std.mem.eql(u8, owned.translation.locale, locale)) {
            try sources.append(arena, .{
                .provider = owned.plugin,
                .first_party = owned.first_party(),
                .po = owned.translation.po,
            });
        }
    }

    return sources.items;
}

fn choices_in(arena: std.mem.Allocator, kept: []const Kept, locale: []const u8) ![]const Choice {
    std.debug.assert(locale.len > 0);

    var choices: std.ArrayList(Choice) = .empty;

    for (kept) |choice| {
        if (std.mem.eql(u8, choice.locale, locale) and choice.id.len > 0) {
            try choices.append(arena, .{
                .context = choice.context,
                .id = choice.id,
                .provider = choice.provider,
            });
        }
    }

    return choices.items;
}

fn seen(earlier: []const OwnedTranslation, locale: []const u8) bool {
    std.debug.assert(locale.len > 0);

    for (earlier) |owned| {
        if (std.mem.eql(u8, owned.translation.locale, locale)) {
            return true;
        }
    }

    return false;
}

test "a language's files merged into one catalogue, the first file winning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const files = [_]OwnedTranslation{
        .{
            .plugin = "language_pl",
            .translation = .{
                .locale = "pl",
                .label = "Polski",
                .domain = "publr",
                .official = true,
                .po = "msgid \"Save\"\nmsgstr \"Zapisz\"\n",
            },
        },
        .{
            .plugin = "language_de",
            .translation = .{
                .locale = "de",
                .label = "Deutsch",
                .domain = "publr",
                .po = "msgid \"Save\"\nmsgstr \"Speichern\"\n",
            },
        },
        .{
            .plugin = "pl_extra",
            .translation = .{
                .locale = "pl",
                .label = "Polski",
                .domain = "publr",
                .po = "msgid \"Save\"\nmsgstr \"Zachowaj\"\nmsgid \"Trash\"\nmsgstr \"Kosz\"\n",
            },
        },
    };
    const list = try build(arena_state.allocator(), &files, &.{});

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("Zapisz", list[0].catalog.lookup("", "Save", null).?);
    try std.testing.expect(std.mem.indexOf(u8, list[0].script, "\"Save\":[\"Zapisz\"]") != null);
    try std.testing.expectEqualStrings("Kosz", list[0].catalog.lookup("", "Trash", null).?);
    try std.testing.expectEqualStrings("Speichern", list[1].catalog.lookup("", "Save", null).?);
}
