//! A record type's editor as its head form sets it: Form or Visual, and for Visual the rich
//! text field the block editor edits (named in `editor_config` only when it is not the
//! first). A type made or turned visual from the admin gets a Title and a Body field when
//! it has none.
const std = @import("std");
const model = @import("../../model.zig");
const admin = @import("../admin.zig");

const Def = model.content_type.Def;
const Form = admin.Form;
const Choice = admin.views.TypeForm.Rich_fieldsItem;

pub const body_field: model.field.Def = .{
    .name = "body",
    .label = "Body",
    .kind = "richtext",
};

fn is_rich(candidate: model.field.Def) bool {
    return std.mem.eql(u8, candidate.kind, "richtext") and !candidate.many;
}

/// `def` with the editor the form chose; as it was when the form did not say.
pub fn chosen(arena: std.mem.Allocator, form: *const Form, def: Def) admin.Error!Def {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(def.fields.len <= model.field.fields_max);

    const editor = form.text("editor") orelse return def;
    const visual = def.kind == .record and std.mem.eql(u8, editor, "visual");
    var out = def;

    out.editor = if (visual) "visual" else "form";
    out.editor_config = "{}";

    const named = form.text("editor_field") orelse "";
    const first = for (def.fields) |candidate| {
        if (is_rich(candidate)) {
            break candidate.name;
        }
    } else "";

    if (visual and named.len > 0 and !std.mem.eql(u8, named, first)) {
        out.editor_config = std.json.Stringify.valueAlloc(arena, .{
            .field = named,
        }, .{}) catch {
            return error.OutOfMemory;
        };
    }

    return with_body(arena, out);
}

/// A visual type has what the block editor and its template need: a Title (the type's
/// title field) first and a Body to edit, each added when the type has none.
pub fn with_body(arena: std.mem.Allocator, def: Def) admin.Error!Def {
    std.debug.assert(def.fields.len < model.field.fields_max);
    std.debug.assert(def.title_field.len > 0);

    if (!model.editor.is_visual(def.editor)) {
        return def;
    }

    var out = def;
    const titled = for (def.fields) |candidate| {
        if (std.mem.eql(u8, candidate.name, def.title_field)) {
            break true;
        }
    } else false;

    if (!titled) {
        const title: model.field.Def = .{
            .name = def.title_field,
            .label = "Title",
            .kind = "string",
        };

        out.fields = try added(arena, out.fields, title, 0);
    }

    for (out.fields) |candidate| {
        if (is_rich(candidate)) {
            return out;
        }
    }

    out.fields = try added(arena, out.fields, body_field, @intCast(out.fields.len));

    return out;
}

fn added(
    arena: std.mem.Allocator,
    fields: []const model.field.Def,
    field: model.field.Def,
    at: u32,
) admin.Error![]const model.field.Def {
    std.debug.assert(at <= fields.len);
    std.debug.assert(fields.len < model.field.fields_max);

    const out = arena.alloc(model.field.Def, fields.len + 1) catch return error.OutOfMemory;

    @memcpy(out[0..at], fields[0..at]);
    out[at] = field;
    @memcpy(out[at + 1 ..], fields[at..]);

    return out;
}

/// Whether `name` is the top-level field a visual type's block editor writes: the one the
/// admin never offers to remove.
pub fn is_edited(def: Def, name: []const u8) bool {
    std.debug.assert(def.fields.len <= model.field.fields_max);
    std.debug.assert(name.len > 0);

    const edited = model.editor.field_of(def.editor, def.editor_config, def.fields) orelse {
        return false;
    };

    return std.mem.eql(u8, edited.name, name);
}

/// The type's rich text fields for the form, the one the editor edits selected.
pub fn choices(arena: std.mem.Allocator, def: Def) admin.Error![]const Choice {
    std.debug.assert(def.fields.len <= model.field.fields_max);

    const edited = model.editor.field_of("visual", def.editor_config, def.fields);
    var out: std.ArrayList(Choice) = .empty;

    for (def.fields) |candidate| {
        if (!is_rich(candidate)) {
            continue;
        }

        const selected = if (edited) |field| std.mem.eql(u8, field.name, candidate.name) else false;

        out.append(arena, .{
            .value = candidate.name,
            .label = candidate.label,
            .selected = selected,
        }) catch return error.OutOfMemory;
    }

    return out.items;
}

test "a visual type gets a Title and a Body when it has none, and only then" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const slug: model.field.Def = .{
        .name = "slug",
        .label = "Slug",
        .kind = "slug",
    };
    const content: model.field.Def = .{
        .name = "content",
        .label = "Content",
        .kind = "richtext",
    };
    const bare: Def = .{
        .handle = "article",
        .name = "Article",
        .editor = "visual",
        .fields = &.{slug},
    };

    const ready = try with_body(arena, bare);

    try std.testing.expectEqual(@as(usize, 3), ready.fields.len);
    try std.testing.expectEqualStrings("title", ready.fields[0].name);
    try std.testing.expectEqualStrings("body", ready.fields[2].name);
    try std.testing.expect(model.editor.field_of(ready.editor, "{}", ready.fields) != null);

    var rich = bare;

    rich.fields = &.{ slug, content };
    try std.testing.expectEqual(@as(usize, 3), (try with_body(arena, rich)).fields.len);

    var form = bare;

    form.editor = "form";
    try std.testing.expectEqual(@as(usize, 1), (try with_body(arena, form)).fields.len);
}

test "the visual editor's field is the edited one, and only while the type is visual" {
    const content: model.field.Def = .{
        .name = "content",
        .label = "Content",
        .kind = "richtext",
    };
    const notes: model.field.Def = .{
        .name = "notes",
        .label = "Notes",
        .kind = "richtext",
    };
    const visual: Def = .{
        .handle = "article",
        .name = "Article",
        .editor = "visual",
        .fields = &.{ content, notes },
    };

    try std.testing.expect(is_edited(visual, "content"));
    try std.testing.expect(!is_edited(visual, "notes"));

    var form = visual;

    form.editor = "form";
    try std.testing.expect(!is_edited(form, "content"));
}
