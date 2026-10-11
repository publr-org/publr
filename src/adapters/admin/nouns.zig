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
    const plural_name = if (def.plural_name.len > 0) def.plural_name else def.name;
    const forms = forms_in(def, session.language.locale);
    var list: std.ArrayList(Placeholder) = .empty;
    var singular = def.name;
    var plural = plural_name;

    if (forms) |found| {
        if (found.forms.len > 0) {
            singular = or_else(found.forms[0].singular, def.name);
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
