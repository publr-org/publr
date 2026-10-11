//! A type's names on its settings form: the plural, and its forms in each admin language
//! whose pack declines nouns (gender, then each case singular and plural), drawn from the
//! definition and read back from the post.
const std = @import("std");
const admin = @import("../admin.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");

const Def = model.content_type.Def;
const NounForms = model.content_type.NounForms;
const NounForm = model.content_type.NounForm;
const Grammar = @import("../../sdk/plugin.zig").Grammar;

const Declining = struct {
    locale: []const u8,
    label: []const u8,
    grammar: Grammar,
};

/// The languages whose packs say how they decline, each once.
const declining = blk: {
    var found: []const Declining = &.{};

    for (registry.translations) |owned| {
        const translation = owned.translation;

        if (translation.grammar.cases.len == 0) continue;

        var seen = false;

        for (found) |known| seen = seen or std.mem.eql(u8, known.locale, translation.locale);

        if (!seen) {
            found = found ++ &[_]Declining{.{
                .locale = translation.locale,
                .label = translation.label,
                .grammar = translation.grammar,
            }};
        }
    }

    break :blk found;
};

/// The forms the form shows, filled from `def`.
pub fn languages_of(
    comptime Language: type,
    arena: std.mem.Allocator,
    def: Def,
) admin.Error![]const Language {
    std.debug.assert(def.noun_forms.len <= 64);
    std.debug.assert(declining.len <= 64);

    const out = try arena.alloc(Language, declining.len);

    for (declining, out) |language, *item| {
        const saved = saved_in(def, language.locale);
        const Gender = @typeInfo(@FieldType(Language, "genders")).pointer.child;
        const Case = @typeInfo(@FieldType(Language, "cases")).pointer.child;
        const genders = try arena.alloc(Gender, language.grammar.genders.len);
        const cases = try arena.alloc(Case, language.grammar.cases.len);

        for (language.grammar.genders, genders) |gender, *shown| {
            shown.* = .{
                .key = gender.key,
                .label = gender.label,
                .selected = std.mem.eql(u8, gender.key, if (saved) |forms| forms.gender else ""),
            };
        }

        for (language.grammar.cases, cases) |case, *shown| {
            const form = if (saved) |forms| form_of(forms, case.key) else null;

            shown.* = .{
                .key = case.key,
                .label = case.label,
                .singular = if (form) |found| found.singular else "",
                .plural = if (form) |found| found.plural else "",
            };
        }

        item.* = .{
            .locale = language.locale,
            .label = language.label,
            .genders = genders,
            .cases = cases,
        };
    }

    return out;
}

fn saved_in(def: Def, locale: []const u8) ?NounForms {
    std.debug.assert(locale.len > 0);

    for (def.noun_forms) |forms| {
        if (std.mem.eql(u8, forms.locale, locale)) return forms;
    }

    return null;
}

fn form_of(forms: NounForms, case: []const u8) ?NounForm {
    std.debug.assert(case.len > 0);

    for (forms.forms) |form| {
        if (std.mem.eql(u8, form.case, case)) return form;
    }

    return null;
}

/// The post's names over `base`: `plural_name`, then `forms.<locale>.gender` and
/// `forms.<locale>.<case>.singular` / `.plural` for each declining language; a language
/// with nothing filled keeps no forms.
pub fn read(arena: std.mem.Allocator, form: *const admin.Form, base: Def) admin.Error!Def {
    std.debug.assert(form.len <= admin.form_pairs_max);

    var def = base;

    def.plural_name = form.text("plural_name") orelse "";

    var all: std.ArrayList(NounForms) = .empty;

    for (declining) |language| {
        const forms = try read_language(arena, form, language);

        if (forms) |filled| {
            try all.append(arena, filled);
        }
    }

    def.noun_forms = all.items;

    return def;
}

fn read_language(
    arena: std.mem.Allocator,
    form: *const admin.Form,
    language: Declining,
) admin.Error!?NounForms {
    std.debug.assert(language.locale.len > 0);

    const gender_key = try std.fmt.allocPrint(arena, "forms.{s}.gender", .{language.locale});
    const gender = form.text(gender_key) orelse "";
    var forms: std.ArrayList(NounForm) = .empty;

    for (language.grammar.cases) |case| {
        const singular = try field(arena, form, language.locale, case.key, "singular");
        const plural = try field(arena, form, language.locale, case.key, "plural");

        if (singular.len > 0 or plural.len > 0) {
            try forms.append(arena, .{
                .case = case.key,
                .singular = singular,
                .plural = plural,
            });
        }
    }

    if (gender.len == 0 and forms.items.len == 0) {
        return null;
    }

    return .{
        .locale = language.locale,
        .gender = gender,
        .forms = forms.items,
    };
}

fn field(
    arena: std.mem.Allocator,
    form: *const admin.Form,
    locale: []const u8,
    case: []const u8,
    comptime number: []const u8,
) admin.Error![]const u8 {
    std.debug.assert(case.len > 0);

    const key = try std.fmt.allocPrint(arena, "forms.{s}.{s}." ++ number, .{ locale, case });

    return std.mem.trim(u8, form.text(key) orelse "", " ");
}
