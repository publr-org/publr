//! The Default value section of the field form: the kind's own control holding the
//! default, or the reason none can be set, as a fragment the page takes as a node.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const time = @import("../../../lib/time.zig");

const Error = admin.Error;
const FieldDef = model.field.Def;
const Kind = model.kinds.Kind;
const views = admin.views.FieldDefault;
const Option = views.OptionsItem;

pub fn node(arena: std.mem.Allocator, field: FieldDef) Error!admin.render.Node {
    std.debug.assert(field.kind.len <= model.kinds.string_len_max);
    std.debug.assert(field.options.choices.len <= model.field.choices_max);

    const kind = model.kinds.lookup(registry.Kinds.all, field.kind);
    const now = std.mem.eql(u8, field.default, model.defaults.now_text);

    return admin.render.view(arena, views, .{
        .blocked = blocked(kind),
        .can_unique = kind.unique_allowed,
        .control = control_of(kind, field),
        .value = try text_of(arena, kind, field),
        .checked = kind.control == .checkbox and field.default.len > 0,
        .options = try options_of(arena, kind, field),
        .can_now = kind.control == .datetime,
        .now = now,
    });
}

/// Why the default cannot be set, or empty when it can; a unique field's refusal
/// follows the Unique checkbox on the form itself.
fn blocked(kind: Kind) []const u8 {
    std.debug.assert(kind.id.len > 0);
    std.debug.assert(kind.id.len <= model.kinds.id_len_max);

    return if (kind.default_allowed) "" else "kind";
}

/// The control the default is edited with: the kind's, a day picker for a date-only
/// field.
fn control_of(kind: Kind, field: FieldDef) []const u8 {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(kind.id.len > 0);

    return switch (kind.control) {
        .input => "input",
        .number => "number",
        .textarea => "textarea",
        .checkbox => "switch",
        .select => "select",
        .datetime => if (field.options.date.format == .date) "date" else "datetime",
        .json => "json",
    };
}

/// The default as its control holds it: a date and time default is printed again in the
/// field's current format, since the format can change after it was typed; `now` shows
/// as an empty control, the checkbox above it carries the choice.
fn text_of(arena: std.mem.Allocator, kind: Kind, field: FieldDef) Error![]const u8 {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(time.ms_max > 0);

    if (kind.control != .datetime or field.default.len == 0) {
        return field.default;
    }

    if (std.mem.eql(u8, field.default, model.defaults.now_text)) {
        return "";
    }

    const value = model.defaults.value_of(kind, field, 0) orelse return field.default;
    const ms = value.integer;

    return switch (field.options.date.format) {
        .datetime => time.datetime_local_text(arena, ms) catch error.OutOfMemory,
        .date => time.date_text(arena, ms) catch error.OutOfMemory,
    };
}

/// A select's choices, the default one selected, labelled as the field labels them.
fn options_of(arena: std.mem.Allocator, kind: Kind, field: FieldDef) Error![]const Option {
    std.debug.assert(field.options.choices.len <= model.field.choices_max);
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));

    if (kind.control != .select) {
        return &.{};
    }

    const labels = field.options.labels;
    const options = try arena.alloc(Option, field.options.choices.len + 1);

    options[0] = .{ .value = "", .label = "None", .selected = field.default.len == 0 };

    for (field.options.choices, 1..) |choice, index| {
        options[index] = .{
            .value = choice,
            .label = if (labels.len == field.options.choices.len) labels[index - 1] else choice,
            .selected = std.mem.eql(u8, choice, field.default),
        };
    }

    return options;
}

test "defaults know their control, their reason, and print dates in the current format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const datetime = model.kinds.find(&model.kinds.core, "datetime").?;
    var day: FieldDef = .{
        .name = "at",
        .label = "At",
        .kind = "datetime",
        .default = "1970-01-03T10:00",
        .options = .{ .date = .{ .format = .date } },
    };
    try std.testing.expectEqualStrings("date", control_of(datetime, day));
    try std.testing.expectEqualStrings("1970-01-03", try text_of(arena, datetime, day));
    day.options.date.format = .datetime;
    try std.testing.expectEqualStrings("1970-01-03T10:00", try text_of(arena, datetime, day));
    day.default = "now";
    try std.testing.expectEqualStrings("", try text_of(arena, datetime, day));
    try std.testing.expectEqualStrings("", blocked(datetime));

    const media = model.kinds.find(&model.kinds.core, "media").?;
    try std.testing.expectEqualStrings("kind", blocked(media));

    const select = model.kinds.find(&model.kinds.core, "select").?;
    const kind: FieldDef = .{
        .name = "kind",
        .label = "Kind",
        .kind = "select",
        .default = "b",
        .options = .{ .choices = &.{ "a", "b" }, .labels = &.{ "Alpha", "Beta" } },
    };
    const options = try options_of(arena, select, kind);
    try std.testing.expectEqual(@as(usize, 3), options.len);
    try std.testing.expectEqualStrings("Beta", options[2].label);
    try std.testing.expect(options[2].selected and !options[0].selected);
}
