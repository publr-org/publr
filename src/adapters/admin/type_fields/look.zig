//! The Appearance section of the field form: the help line, the placeholder, and what
//! the kind lets you shape, as a fragment the page takes as a node.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const rules = @import("rules.zig");

const Error = admin.Error;
const FieldDef = model.field.Def;
const Kind = model.kinds.Kind;
const views = admin.views.FieldLook;
const Props = views.Props;
const LabelField = views.Label_fieldsItem;

pub fn node(arena: std.mem.Allocator, field: FieldDef) Error!admin.render.Node {
    std.debug.assert(field.kind.len <= model.kinds.string_len_max);
    std.debug.assert(field.fields.len <= model.field.fields_max);

    const kind = model.kinds.lookup(registry.Kinds.all, field.kind);
    const set = field.options;
    var props: Props = .{
        .help = field.help,
        .help_count = try rules.room_text(arena, field.help.len, model.field.help_len_max),
        .label_fields = try label_fields_of(arena, field),
    };

    props.has_placeholder = kind.control == .input or kind.control == .number or
        kind.control == .textarea;
    props.placeholder = set.placeholder;
    props.has_rows = kind.has.rows;
    props.rows = try rules.count_text(arena, set.rows);
    props.has_text_format = std.mem.eql(u8, kind.id, "text");
    props.markdown = set.text.format == .markdown;
    props.has_date_format = kind.has.dates;
    props.date_only = set.date.format == .date;
    props.has_slug = std.mem.eql(u8, kind.id, "slug");
    props.lock_on_publish = set.slug.lock_on_publish;
    props.has_email = std.mem.eql(u8, kind.id, "email");
    props.lowercase = set.email.lowercase;
    props.has_media = kind.has.media;
    props.media_create = set.media.create;
    props.media_link = set.media.link;

    fill_controls(&props, kind, field);
    try fill_numbers(&props, arena, kind, field);

    return admin.render.view(arena, views, props);
}

/// A boolean's labels and control, a select's control, a reference's buttons, a
/// container's header.
fn fill_controls(props: *Props, kind: Kind, field: FieldDef) void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(kind.id.len > 0);

    const set = field.options;

    props.has_boolean = kind.storage == .bool;
    props.true_label = set.boolean.true_label;
    props.false_label = set.boolean.false_label;
    props.boolean_control = @tagName(set.boolean.control);
    props.has_select = kind.control == .select;
    props.select_list = set.select.control == .list;
    props.select_buttons = set.select.control == .buttons;
    props.has_reference = std.mem.eql(u8, kind.id, "reference");
    props.reference_create = set.reference.create;
    props.reference_live_only = set.reference.live_only;
    props.reference_public_only = set.reference.public_only;
    props.reference_link = set.reference.link;
    props.has_container = model.field.is_container(field.kind);
    props.collapsed = set.container.collapsed;
    props.has_label_field = model.field.is_repeater(field.kind) and field.fields.len > 0;
    props.label_field_none = set.container.label_field.len == 0;
    props.add_label = set.container.add_label;
}

fn fill_numbers(props: *Props, arena: std.mem.Allocator, kind: Kind, field: FieldDef) Error!void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(kind.id.len > 0);

    const set = field.options;

    props.has_number = kind.control == .number;
    props.unit = set.number.unit;
    props.unit_after = set.number.unit_after;
    props.has_decimals = kind.storage == .real;
    props.decimals = try rules.count_text(arena, set.number.decimals);
    props.number_control = @tagName(set.number.control);
    props.can_rating = kind.storage == .int and kind.control == .number;
}

/// The fields inside a repeater, as the choices of its item label.
fn label_fields_of(arena: std.mem.Allocator, field: FieldDef) Error![]const LabelField {
    std.debug.assert(field.fields.len <= model.field.fields_max);
    std.debug.assert(field.options.container.label_field.len <= model.field.name_len_max);

    const chosen = field.options.container.label_field;
    const items = try arena.alloc(LabelField, field.fields.len);

    for (field.fields, 0..) |child, index| {
        items[index] = .{
            .value = child.name,
            .label = child.label,
            .selected = std.mem.eql(u8, child.name, chosen),
        };
    }

    return items;
}

test "the look follows the kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const integer = model.kinds.find(&model.kinds.core, "integer").?;
    const stars: FieldDef = .{ .name = "stars", .label = "Stars", .kind = "integer", .options = .{
        .number = .{ .unit = "*", .control = .rating },
    } };
    var props: Props = .{ .help = "", .help_count = "", .label_fields = &.{} };
    try fill_numbers(&props, arena, integer, stars);
    try std.testing.expect(props.has_number and props.can_rating and !props.has_decimals);
    try std.testing.expectEqualStrings("rating", props.number_control);

    const repeater = model.kinds.find(&model.kinds.core, "repeater").?;
    const faq: FieldDef = .{ .name = "faq", .label = "FAQ", .kind = "repeater", .options = .{
        .container = .{ .label_field = "question", .add_label = "Add question" },
    }, .fields = &.{
        .{ .name = "question", .label = "Question", .kind = "string" },
    } };
    const label_fields = try label_fields_of(arena, faq);
    var boxed: Props = .{ .help = "", .help_count = "", .label_fields = label_fields };
    fill_controls(&boxed, repeater, faq);
    try std.testing.expect(boxed.has_container and boxed.has_label_field);
    try std.testing.expect(!boxed.label_field_none);
    try std.testing.expect(boxed.label_fields[0].selected);
    try std.testing.expectEqualStrings("Add question", boxed.add_label);
}
