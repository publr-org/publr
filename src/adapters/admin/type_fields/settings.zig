//! The choices and the look of a field's kind, read from the field form: what a select
//! offers, a reference points at and how it behaves, a slug is made from, how a text
//! box, a date, a boolean, a number, a container and a media field are shown.
const std = @import("std");
const admin = @import("../../admin.zig");
const model = @import("../../../model.zig");
const options = @import("options.zig");

const Error = admin.Error;
const Form = admin.Form;
const FieldDef = model.field.Def;
const Kind = model.kinds.Kind;
const settings_options = model.field.options;

const lines_bytes_max: u32 = 64 << 10;

pub fn read(arena: std.mem.Allocator, form: *const Form, kind: Kind, field: *FieldDef) Error!void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(form.len <= admin.form_pairs_max);

    var set = &field.options;

    if (kind.has.rows) {
        set.rows = options.count_of(form, "rows");
    }

    if (kind.has.source) {
        set.source = form.text("source") orelse "";
    }

    if (kind.control == .select) {
        try read_choices(arena, form.text("choices") orelse "", set);
        set.select.control = if (form.get("select_control")) |wanted|
            std.meta.stringToEnum(settings_options.SelectControl, wanted) orelse .dropdown
        else
            .dropdown;
    }

    if (kind.has.taxonomy) {
        set.taxonomy = form.text("taxonomy") orelse "";
    }

    if (kind.has.target) {
        set.to = try values_of(arena, form, "to");
        set.reference.create = form.get("reference_create") != null;
        set.reference.live_only = form.get("reference_live_only") != null;
        set.reference.public_only = form.get("reference_public_only") != null;
        set.reference.link = form.get("reference_link") != null;
        set.reference.on_delete = if (form.get("on_delete")) |wanted|
            std.meta.stringToEnum(settings_options.OnDelete, wanted) orelse .keep
        else
            .keep;
    }

    if (kind.has.dates) {
        const wanted = form.text("date_format") orelse "datetime";

        const DateFormat = settings_options.DateFormat;

        set.date.format = std.meta.stringToEnum(DateFormat, wanted) orelse .datetime;
    }

    if (std.mem.eql(u8, kind.id, "text")) {
        const wanted = form.text("text_format") orelse "plain";

        set.text.format = std.meta.stringToEnum(settings_options.TextFormat, wanted) orelse .plain;
    }

    const is_slug = std.mem.eql(u8, kind.id, "slug");

    set.slug.lock_on_publish = is_slug and form.get("lock_on_publish") != null;
    set.email.lowercase = std.mem.eql(u8, kind.id, "email") and form.get("lowercase") != null;

    read_controls(form, kind, field);
}

/// A boolean's labels and control, a number's unit and control, a container's header.
fn read_controls(form: *const Form, kind: Kind, field: *FieldDef) void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(form.len <= admin.form_pairs_max);

    var set = &field.options;

    if (kind.storage == .bool) {
        const wanted = form.text("boolean_control") orelse "toggle";

        set.boolean.true_label = form.text("true_label") orelse "";
        set.boolean.false_label = form.text("false_label") orelse "";
        const BooleanControl = settings_options.BooleanControl;

        set.boolean.control = std.meta.stringToEnum(BooleanControl, wanted) orelse .toggle;
    }

    if (kind.control == .number) {
        const wanted = form.text("number_control") orelse "input";
        const control = std.meta.stringToEnum(settings_options.NumberControl, wanted) orelse .input;

        set.number.unit = form.text("unit") orelse "";
        set.number.unit_after = !std.mem.eql(u8, form.text("unit_after") orelse "1", "0");
        set.number.decimals = if (kind.storage == .real)
            options.count_of(form, "decimals")
        else
            null;
        set.number.control = if (control == .rating and kind.storage != .int) .input else control;
    }

    if (model.field.is_container(field.kind)) {
        set.container.collapsed = form.get("collapsed") != null;
        set.container.label_field = form.text("label_field") orelse "";
        set.container.add_label = form.text("add_label") orelse "";
    }
}

/// One choice per line, `value | Label` where the label differs; labels are kept only
/// when at least one line has one.
fn read_choices(arena: std.mem.Allocator, text: []const u8, set: *model.field.Options) Error!void {
    std.debug.assert(set.choices.len <= model.field.choices_max);
    std.debug.assert(model.field.choices_max > 0);

    const lines = try lines_of(arena, text);
    const choices = try arena.alloc([]const u8, lines.len);
    const labels = try arena.alloc([]const u8, lines.len);
    var labelled = false;

    for (lines, 0..) |line, index| {
        if (std.mem.indexOf(u8, line, "|")) |bar| {
            choices[index] = std.mem.trim(u8, line[0..bar], " \t");
            labels[index] = std.mem.trim(u8, line[bar + 1 ..], " \t");
            labelled = labelled or labels[index].len > 0;
        } else {
            choices[index] = line;
            labels[index] = line;
        }

        if (labels[index].len == 0) {
            labels[index] = choices[index];
        }
    }

    set.choices = choices;
    set.labels = if (labelled) labels else &.{};
}

/// One entry per line, trimmed, empty lines skipped, up to the choices cap.
pub fn lines_of(arena: std.mem.Allocator, text: []const u8) Error![]const []const u8 {
    std.debug.assert(model.field.choices_max > 0);
    std.debug.assert(lines_bytes_max > 0);

    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, text, '\n');

    while (split.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");

        if (line.len == 0 or lines.items.len == model.field.choices_max) {
            continue;
        }

        lines.append(arena, line) catch return error.OutOfMemory;
    }

    return lines.items;
}

/// Every value posted under `name`, in order: the checked boxes of a list.
pub fn values_of(
    arena: std.mem.Allocator,
    form: *const Form,
    name: []const u8,
) Error![]const []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    var values: std.ArrayList([]const u8) = .empty;

    for (form.pairs[0..form.len]) |pair| {
        if (std.mem.eql(u8, pair.name, name) and pair.value.len > 0) {
            values.append(arena, pair.value) catch return error.OutOfMemory;
        }
    }

    return values.items;
}

test "choices come one per line, labelled with a bar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lines = try lines_of(arena, " draft \r\n\nfinal\n");
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("draft", lines[0]);
    try std.testing.expectEqualStrings("final", lines[1]);
    try std.testing.expectEqual(@as(usize, 0), (try lines_of(arena, "")).len);

    var plain: model.field.Options = .{};
    try read_choices(arena, "a\nb", &plain);
    try std.testing.expectEqual(@as(usize, 2), plain.choices.len);
    try std.testing.expectEqual(@as(usize, 0), plain.labels.len);

    var labelled: model.field.Options = .{};
    try read_choices(arena, "a | Alpha\nb\nc |", &labelled);
    try std.testing.expectEqual(@as(usize, 3), labelled.labels.len);
    try std.testing.expectEqualStrings("Alpha", labelled.labels[0]);
    try std.testing.expectEqualStrings("b", labelled.labels[1]);
    try std.testing.expectEqualStrings("c", labelled.choices[2]);
    try std.testing.expectEqualStrings("c", labelled.labels[2]);
}

test "the look of a kind is read from its own controls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const boolean = model.kinds.find(&model.kinds.core, "boolean").?;
    var shown: FieldDef = .{ .name = "shown", .label = "Shown", .kind = "boolean" };
    const flags = Form.parse(arena, "true_label=Yes&false_label=No&boolean_control=radio").?;
    try read(arena, &flags, boolean, &shown);
    try std.testing.expectEqualStrings("Yes", shown.options.boolean.true_label);
    const radio = settings_options.BooleanControl.radio;
    try std.testing.expectEqual(radio, shown.options.boolean.control);

    const number = model.kinds.find(&model.kinds.core, "number").?;
    var price: FieldDef = .{ .name = "price", .label = "Price", .kind = "number" };
    const money = Form.parse(arena, "unit=%24&unit_after=0&decimals=2&number_control=rating").?;
    try read(arena, &money, number, &price);
    try std.testing.expectEqualStrings("$", price.options.number.unit);
    try std.testing.expect(!price.options.number.unit_after);
    try std.testing.expectEqual(@as(u32, 2), price.options.number.decimals.?);
    try std.testing.expectEqual(settings_options.NumberControl.input, price.options.number.control);

    const reference = model.kinds.find(&model.kinds.core, "reference").?;
    var author: FieldDef = .{ .name = "author", .label = "Author", .kind = "reference" };
    const linked = Form.parse(arena, "to=author&reference_link=1&on_delete=clear").?;
    try read(arena, &linked, reference, &author);
    try std.testing.expect(!author.options.reference.create and author.options.reference.link);
    const clear = settings_options.OnDelete.clear;
    try std.testing.expectEqual(clear, author.options.reference.on_delete);

    const repeater = model.kinds.find(&model.kinds.core, "repeater").?;
    var faq: FieldDef = .{ .name = "faq", .label = "FAQ", .kind = "repeater" };
    const boxed = Form.parse(arena, "collapsed=1&label_field=question&add_label=Add+question").?;
    try read(arena, &boxed, repeater, &faq);
    try std.testing.expect(faq.options.container.collapsed);
    try std.testing.expectEqualStrings("question", faq.options.container.label_field);
    try std.testing.expectEqualStrings("Add question", faq.options.container.add_label);
}
