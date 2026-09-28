//! The Validation section of the field form, drawn from the kind's descriptor (which
//! rules it has) and the field (what is set), as a fragment the page takes as a node.
//! Every prop of the view has a default, so each group is filled only for the kinds
//! that have it.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const type_pages = @import("../types.zig");
const time = @import("../../../lib/time.zig");

const Error = admin.Error;
const FieldDef = model.field.Def;
const Kind = model.kinds.Kind;
const views = admin.views.FieldRules;
const Props = views.Props;
const MediaType = views.Media_typesItem;
const Scheme = views.SchemesItem;
const print = type_pages.print;

const kib: u64 = 1024;
const mib: u64 = 1024 * 1024;

/// A file size as the number and the unit the form shows: the largest unit that
/// divides it, so `2 MB` comes back as typed.
const Size = struct { amount: []const u8, unit: []const u8 };

pub fn node(arena: std.mem.Allocator, field: FieldDef) Error!admin.render.Node {
    std.debug.assert(field.kind.len <= model.kinds.string_len_max);
    std.debug.assert(field.options.choices.len <= model.field.choices_max);

    const kind = model.kinds.lookup(registry.Kinds.all, field.kind);
    var props: Props = .{
        .schemes = try schemes_of(arena, field.options.url.schemes),
        .media_types = try media_types_of(arena, field.options.media.types),
    };

    try fill_common(&props, arena, kind, field);
    try fill_text(&props, arena, kind, field);
    try fill_numbers(&props, arena, kind, field);
    try fill_links(&props, arena, kind, field);
    try fill_media(&props, arena, kind, field);

    return admin.render.view(arena, views, props);
}

/// Required, unique, the number of values: rules that are not the kind's own.
fn fill_common(props: *Props, arena: std.mem.Allocator, kind: Kind, field: FieldDef) Error!void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(kind.id.len > 0);

    const set = field.options;
    const is_group = model.field.is_group(field.kind);
    const is_boolean = kind.storage == .bool;

    props.can_require = !is_group and !is_boolean;
    props.many_choice = kind.many_allowed;
    props.required = field.required;
    props.can_unique = kind.unique_allowed;
    props.unique = field.unique;
    // Single or Multiple is chosen on the same form, so the rule shows whenever it could
    // apply; it is read only when the field holds many values.
    props.has_items = kind.many_allowed or model.field.is_repeater(field.kind);
    props.limit_items = set.items_min != null or set.items_max != null;
    props.items_min = try count_text(arena, set.items_min);
    props.items_max = try count_text(arena, set.items_max);
    props.distinct = set.distinct;
    props.items_message = set.messages.items;
    props.has_live_only = std.mem.eql(u8, kind.id, "reference");
    props.live_only = set.reference.live_only;
}

fn fill_text(props: *Props, arena: std.mem.Allocator, kind: Kind, field: FieldDef) Error!void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(kind.id.len > 0);

    const set = field.options;

    props.has_length = kind.has.length;
    props.limit_length = set.min_len != null or set.max_len != null;
    props.min_len = try count_text(arena, set.min_len);
    props.max_len = try count_text(arena, set.max_len);
    props.length_message = set.messages.length;
    props.has_words = kind.has.words;
    props.limit_words = set.words_min != null or set.words_max != null;
    props.words_min = try count_text(arena, set.words_min);
    props.words_max = try count_text(arena, set.words_max);
    props.words_message = set.messages.words;
    props.has_pattern = kind.has.pattern;
    props.limit_pattern = set.preset != .any or set.pattern.len > 0;
    props.preset = @tagName(set.preset);
    props.pattern = set.pattern;
    props.pattern_message = set.messages.pattern;
}

fn fill_numbers(props: *Props, arena: std.mem.Allocator, kind: Kind, field: FieldDef) Error!void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(kind.id.len > 0);

    const set = field.options;
    const listed = kind.has.choices and kind.control != .select;

    props.has_range = kind.has.range;
    props.has_dates = kind.has.dates;
    props.limit_range = set.min != null or set.max != null or set.step != null;
    props.min = try bound_text(arena, kind, set.min);
    props.max = try bound_text(arena, kind, set.max);
    props.step = try number_text(arena, set.step);
    props.range_message = set.messages.range;
    props.from_now = set.date.from_now;
    props.has_number_choices = listed;
    props.limit_choices = listed and set.choices.len > 0;
    props.number_choices = if (listed) try join_lines(arena, set.choices) else "";
    props.choices_message = set.messages.choices;
}

/// What a slug, an email and a url each keep out.
fn fill_links(props: *Props, arena: std.mem.Allocator, kind: Kind, field: FieldDef) Error!void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(kind.id.len > 0);

    const set = field.options;

    props.has_reserved = std.mem.eql(u8, kind.id, "slug");
    props.limit_reserved = set.slug.reserved.len > 0;
    props.reserved = try join_lines(arena, set.slug.reserved);
    props.reserved_message = set.messages.reserved;
    props.has_domains = std.mem.eql(u8, kind.id, "email");
    props.limit_domains = set.email.domains.len > 0;
    props.domains = try join_lines(arena, set.email.domains);
    props.domain_message = set.messages.domain;
    props.has_url = std.mem.eql(u8, kind.id, "url");
    props.limit_schemes = set.url.schemes.len > 0;
    props.scheme_message = set.messages.scheme;
    props.limit_hosts = set.url.hosts.len > 0;
    props.hosts = try join_lines(arena, set.url.hosts);
    props.host_message = set.messages.host;
}

fn fill_media(props: *Props, arena: std.mem.Allocator, kind: Kind, field: FieldDef) Error!void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(kind.id.len > 0);

    const set = field.options;
    const media = set.media;
    const size_min = try size_of(arena, media.size_min);
    const size_max = try size_of(arena, media.size_max);

    props.has_media = kind.has.media;
    props.limit_size = media.size_min != null or media.size_max != null;
    props.size_min = size_min.amount;
    props.size_min_unit = size_min.unit;
    props.size_max = size_max.amount;
    props.size_max_unit = size_max.unit;
    props.size_message = set.messages.size;
    props.limit_types = media.types.len > 0;
    props.types_message = set.messages.types;
    props.limit_dimensions = media.width_min != null or media.width_max != null or
        media.height_min != null or media.height_max != null;
    props.width_min = try count_text(arena, media.width_min);
    props.width_max = try count_text(arena, media.width_max);
    props.height_min = try count_text(arena, media.height_min);
    props.height_max = try count_text(arena, media.height_max);
    props.dimensions_message = set.messages.dimensions;
}

/// Every file family the field can be limited to, the chosen ones ticked.
fn media_types_of(arena: std.mem.Allocator, chosen: []const []const u8) Error![]const MediaType {
    std.debug.assert(chosen.len <= model.field.options.media_types_max);
    std.debug.assert(model.field.options.media_types.len > 0);

    const known = model.field.options.media_types;
    const items = try arena.alloc(MediaType, known.len);

    for (known, 0..) |media_type, index| {
        items[index] = .{
            .value = media_type.id,
            .label = media_type.label,
            .selected = model.field.options.contains(chosen, media_type.id),
        };
    }

    return items;
}

/// Every scheme a url field can be limited to, the chosen ones ticked.
fn schemes_of(arena: std.mem.Allocator, chosen: []const []const u8) Error![]const Scheme {
    std.debug.assert(chosen.len <= model.field.options.list_max);
    std.debug.assert(model.field.options.url_schemes.len > 0);

    const known = model.field.options.url_schemes;
    const items = try arena.alloc(Scheme, known.len);

    for (known, 0..) |scheme, index| {
        items[index] = .{
            .value = scheme,
            .label = scheme,
            .selected = model.field.options.contains(chosen, scheme),
        };
    }

    return items;
}

/// A range bound as the form shows it: a number, or the day of a date field's bound.
fn bound_text(arena: std.mem.Allocator, kind: Kind, bound: ?f64) Error![]const u8 {
    std.debug.assert(kind.id.len > 0);
    std.debug.assert(time.ms_max > 0);

    const value = bound orelse return "";

    if (!kind.has.dates) {
        return number_text(arena, value);
    }

    if (!std.math.isFinite(value) or value < 0 or value >= @as(f64, @floatFromInt(time.ms_max))) {
        return "";
    }

    return time.date_text(arena, @intFromFloat(value)) catch error.OutOfMemory;
}

fn size_of(arena: std.mem.Allocator, bytes: ?u64) Error!Size {
    std.debug.assert(mib > kib);
    std.debug.assert(kib > 1);

    const value = bytes orelse return .{ .amount = "", .unit = "b" };

    if (value > 0 and value % mib == 0) {
        return .{ .amount = try print(arena, "{d}", .{value / mib}), .unit = "mb" };
    }

    if (value > 0 and value % kib == 0) {
        return .{ .amount = try print(arena, "{d}", .{value / kib}), .unit = "kb" };
    }

    return .{ .amount = try print(arena, "{d}", .{value}), .unit = "b" };
}

pub fn join_lines(arena: std.mem.Allocator, lines: []const []const u8) Error![]const u8 {
    std.debug.assert(lines.len <= model.field.choices_max);
    std.debug.assert(kib > 0);

    return std.mem.join(arena, "\n", lines) catch error.OutOfMemory;
}

pub fn count_text(arena: std.mem.Allocator, count: ?u32) Error![]const u8 {
    std.debug.assert(kib > 0);

    const value = count orelse return "";

    std.debug.assert(value <= std.math.maxInt(u32));

    return print(arena, "{d}", .{value});
}

/// `12 / 64`: how much of a text's room is used, as the counter under it shows.
pub fn room_text(arena: std.mem.Allocator, used: u64, max: u32) Error![]const u8 {
    std.debug.assert(max > 0);
    std.debug.assert(used <= 64 << 10);

    return print(arena, "{d} / {d}", .{ used, max });
}

pub fn number_text(arena: std.mem.Allocator, number: ?f64) Error![]const u8 {
    std.debug.assert(kib > 0);

    const value = number orelse return "";

    std.debug.assert(!std.math.isNan(value));

    return print(arena, "{d}", .{value});
}

test "sizes come back in the unit they were typed in; groups follow the kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const two_mb = try size_of(arena, 2 * mib);
    try std.testing.expectEqualStrings("2", two_mb.amount);
    try std.testing.expectEqualStrings("mb", two_mb.unit);
    const half_kb = try size_of(arena, 512);
    try std.testing.expectEqualStrings("512", half_kb.amount);
    try std.testing.expectEqualStrings("b", half_kb.unit);
    try std.testing.expectEqualStrings("", (try size_of(arena, null)).amount);

    const datetime = model.kinds.find(&model.kinds.core, "datetime").?;
    const day: FieldDef = .{
        .name = "at",
        .label = "At",
        .kind = "datetime",
        .options = .{ .date = .{ .format = .date, .from_now = true }, .min = 86_400_000 },
    };
    const earliest = try bound_text(arena, datetime, day.options.min);
    try std.testing.expectEqualStrings("1970-01-02", earliest);
    var dated: Props = .{ .schemes = &.{}, .media_types = &.{} };
    try fill_numbers(&dated, arena, datetime, day);
    try std.testing.expect(dated.has_dates and dated.from_now and dated.limit_range);

    const group = model.kinds.find(&model.kinds.core, "group").?;
    const seo: FieldDef = .{ .name = "seo", .label = "SEO", .kind = "group" };
    var grouped: Props = .{ .schemes = &.{}, .media_types = &.{} };
    try fill_common(&grouped, arena, group, seo);
    try std.testing.expect(!grouped.can_require and !grouped.has_items);
    const string = model.kinds.find(&model.kinds.core, "string").?;
    const one: FieldDef = .{ .name = "one", .label = "One", .kind = "string" };
    var single: Props = .{ .schemes = &.{}, .media_types = &.{} };
    try fill_common(&single, arena, string, one);
    try std.testing.expect(single.has_items and !single.limit_items);
    try std.testing.expect(single.many_choice and single.can_unique);

    const url = model.kinds.find(&model.kinds.core, "url").?;
    const site: FieldDef = .{ .name = "site", .label = "Site", .kind = "url", .options = .{
        .url = .{ .schemes = &.{"https"}, .hosts = &.{ "a.io", "b.io" } },
    } };
    const schemes = try schemes_of(arena, site.options.url.schemes);
    var linked: Props = .{ .schemes = schemes, .media_types = &.{} };
    try fill_links(&linked, arena, url, site);
    try std.testing.expect(linked.has_url and linked.limit_schemes and linked.limit_hosts);
    try std.testing.expectEqualStrings("a.io\nb.io", linked.hosts);
    try std.testing.expect(linked.schemes[1].selected and !linked.schemes[0].selected);
}
