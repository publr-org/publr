//! A type's name as the person's language declines it, for messages that name it:
//! `{type}` and `{types}` (the name, singular and plural), `{type:genitive}` and
//! `{types:genitive}` (a case's forms), `{type.gender}` (for `select`). A form the type
//! leaves out reads the name.
const std = @import("std");
const admin = @import("../admin.zig");
const model = @import("../../model.zig");

const Def = model.content_type.Def;
const Placeholder = admin.Placeholder;

/// The placeholders that name `def` in the session's language.
pub fn values(session: *const admin.Session, def: Def) admin.Error![]const Placeholder {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(def.noun_forms.len <= 64);

    const arena = session.arena;
    const plural_name = try plural_of(session, def);
    const forms = forms_in(def, session.language.locale) orelse try declared_forms(session, def);
    var list: std.ArrayList(Placeholder) = .empty;
    var singular = try label_of(session, def);
    var plural = plural_name;

    if (forms) |found| {
        if (found.forms.len > 0) {
            singular = or_else(found.forms[0].singular, singular);
            plural = or_else(found.forms[0].plural, plural_name);
        }

        try append(arena, &list, "type.gender", found.gender);

        for (found.forms) |form| {
            const one = or_else(form.singular, singular);
            const many = or_else(form.plural, plural);

            try append(arena, &list, try key(arena, "type:", form.case), one);
            try append(arena, &list, try key(arena, "types:", form.case), many);
        }
    }

    try append(arena, &list, "type", singular);
    try append(arena, &list, "types", plural);

    return list.items;
}

/// The type's name in the session's language: its own form there, else the name as typed.
pub fn name_of(session: *const admin.Session, def: Def) []const u8 {
    std.debug.assert(def.name.len > 0);

    const forms = forms_in(def, session.language.locale) orelse return def.name;

    return if (forms.forms.len > 0) or_else(forms.forms[0].singular, def.name) else def.name;
}

/// The type's name as lists, menus and titles show it: a type people made as typed (its
/// own form in the session's language, when it has one), a plugin's or the core's in the
/// session's language from the catalogues.
pub fn label_of(session: *const admin.Session, def: Def) admin.Error![]const u8 {
    std.debug.assert(def.name.len > 0);

    if (def.system) {
        return session.declared(def.name);
    }

    return name_of(session, def);
}

/// The name for more than one, as `label_of` reads it.
pub fn plural_of(session: *const admin.Session, def: Def) admin.Error![]const u8 {
    std.debug.assert(def.name.len > 0);

    const plural = if (def.plural_name.len > 0) def.plural_name else def.name;

    return if (def.system) session.declared(plural) else plural;
}

/// A type's name from a list of types (`content_type.list`), as `label_of` reads it.
pub fn summary_label(
    session: *const admin.Session,
    system: bool,
    name: []const u8,
) admin.Error![]const u8 {
    std.debug.assert(name.len > 0);

    return if (system) session.declared(name) else name;
}

/// A list of types (`content_type.list`) with each name as `label_of` reads it.
pub fn summaries(
    session: *const admin.Session,
    comptime Summary: type,
    listed: []const Summary,
) admin.Error![]const Summary {
    std.debug.assert(listed.len <= 1 << 16);

    const out = session.arena.alloc(Summary, listed.len) catch return error.OutOfMemory;

    for (listed, out) |summary, *shown| {
        shown.* = summary;
        shown.name = try summary_label(session, summary.system, summary.name);
    }

    return out;
}

/// A plugin's or the core's type declined in the session's language, as the language's PO
/// file writes its forms (`msgctxt "type-forms"`); null where it writes none.
fn declared_forms(
    session: *const admin.Session,
    def: Def,
) admin.Error!?model.content_type.NounForms {
    std.debug.assert(def.name.len > 0);

    if (!def.system or session.language.locale.len == 0) {
        return null;
    }

    const text_forms = model.noun_forms_text;
    const text = try session.translated_in(text_forms.context, def.name);

    if (text.ptr == def.name.ptr or std.mem.eql(u8, text, def.name)) {
        return null;
    }

    return text_forms.parse(session.arena, session.language.locale, text) catch error.OutOfMemory;
}

fn forms_in(def: Def, locale: []const u8) ?model.content_type.NounForms {
    std.debug.assert(locale.len > 0);

    for (def.noun_forms) |forms| {
        if (std.mem.eql(u8, forms.locale, locale)) {
            return forms;
        }
    }

    return null;
}

fn or_else(text: []const u8, fallback: []const u8) []const u8 {
    std.debug.assert(fallback.len > 0);

    return if (text.len > 0) text else fallback;
}

fn key(arena: std.mem.Allocator, prefix: []const u8, case: []const u8) admin.Error![]const u8 {
    std.debug.assert(case.len > 0);

    return std.mem.concat(arena, u8, &.{ prefix, case }) catch error.OutOfMemory;
}

fn append(
    arena: std.mem.Allocator,
    list: *std.ArrayList(Placeholder),
    name: []const u8,
    value: []const u8,
) admin.Error!void {
    std.debug.assert(name.len > 0);

    list.append(arena, .{
        .name = name,
        .value = value,
    }) catch return error.OutOfMemory;
}
