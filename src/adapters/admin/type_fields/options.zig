//! The field form read back into a field definition: the settings every field has, then
//! the rules of its kind. A rule the editor left unticked is dropped with its bounds
//! and message, so the definition carries only what is on. The choices and the look of
//! the kind are read by `settings.zig`.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const type_pages = @import("../types.zig");
const field_pages = @import("../type_fields.zig");
const settings = @import("settings.zig");
const time = @import("../../../lib/time.zig");

const Error = admin.Error;
const Form = admin.Form;
const FieldDef = model.field.Def;
const Kind = model.kinds.Kind;
const Preset = model.field.options.Preset;

const day_ms: i64 = 86_400_000;
const kib: u64 = 1024;
const mib: u64 = 1024 * 1024;

/// The form over `base`: name (made from the label when empty), label, settings and
/// the options of its kind. Options the kind has no control for stay as they are.
pub fn field_of(arena: std.mem.Allocator, form: *const Form, base: FieldDef) Error!FieldDef {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(base.fields.len <= model.field.fields_max);

    var field = base;

    if (field.fields.len == 0) {
        field.fields = model.field.presets.children(field.kind);
    }

    const label = form.text("label") orelse "";
    const kind = model.kinds.lookup(registry.Kinds.all, field.kind);

    field.label = label;
    field.name = form.text("name") orelse try type_pages.handle_of(arena, label);
    field.required = !model.field.is_layout(field.kind) and form.get("required") != null;
    field.unique = kind.unique_allowed and form.get("unique") != null;
    field.searchable = field_pages.can_search(field.kind) and form.get("searchable") != null;
    field.help = form.text("help") orelse "";

    if (form.get("conditions_present") != null) {
        field.conditions = try @import("../field_conditions.zig").read(arena, form, "conditions");
    }

    field.default = if (kind.default_allowed) default_of(kind, form) else "";
    field.options.placeholder = form.text("placeholder") orelse "";
    // Single or Multiple is chosen once: the form does not post it when editing, and
    // stored values already have that shape.
    if (form.text("many")) |many| {
        field.many = field_pages.can_be_many(field.kind) and std.mem.eql(u8, many, "1");
    }

    try read_rules(arena, form, kind, &field);
    read_shape(form, kind, &field);
    try read_lists(arena, form, kind, &field);

    if (kind.has.media) {
        try read_media(arena, form, &field.options.media, &field.options.messages);
    }

    try settings.read(arena, form, kind, &field);

    return field;
}

/// The default as the text its control posts: a switch posts nothing when off; a date
/// and time field may take the moment of creation instead.
fn default_of(kind: Kind, form: *const Form) []const u8 {
    std.debug.assert(kind.default_allowed);
    std.debug.assert(form.len <= admin.form_pairs_max);

    if (kind.control == .checkbox) {
        return if (form.get("default") != null) "1" else "";
    }

    if (kind.control == .datetime and form.get("default_now") != null) {
        return model.defaults.now_text;
    }

    return form.text("default") orelse "";
}

/// The bounds: each rule is on while its box is ticked, and off means no bounds and no
/// message.
fn read_rules(
    arena: std.mem.Allocator,
    form: *const Form,
    kind: Kind,
    field: *FieldDef,
) Error!void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(form.len <= admin.form_pairs_max);

    var set = &field.options;
    const listed = field.many or model.field.is_repeater(field.kind);
    const items_on = listed and form.get("limit_items") != null;
    const length_on = kind.has.length and form.get("limit_length") != null;
    const words_on = kind.has.words and form.get("limit_words") != null;
    const range_on = kind.has.range and form.get("limit_range") != null;
    const numbers = kind.has.choices and kind.control != .select;
    const choices_on = numbers and form.get("limit_choices") != null;

    set.items_min = if (items_on) count_of(form, "items_min") else null;
    set.items_max = if (items_on) count_of(form, "items_max") else null;
    set.messages.items = if (items_on) form.text("items_message") orelse "" else "";
    set.distinct = listed and form.get("distinct") != null;
    set.min_len = if (length_on) count_of(form, "min_len") else null;
    set.max_len = if (length_on) count_of(form, "max_len") else null;
    set.messages.length = if (length_on) form.text("length_message") orelse "" else "";
    set.words_min = if (words_on) count_of(form, "words_min") else null;
    set.words_max = if (words_on) count_of(form, "words_max") else null;
    set.messages.words = if (words_on) form.text("words_message") orelse "" else "";
    set.min = if (range_on) bound_of(form, kind, "min", false) else null;
    set.max = if (range_on) bound_of(form, kind, "max", true) else null;
    set.step = if (range_on and !kind.has.dates) number_of(form, "step") else null;
    set.messages.range = if (range_on) form.text("range_message") orelse "" else "";
    set.date.from_now = kind.has.dates and form.get("from_now") != null;
    set.messages.choices = if (choices_on) form.text("choices_message") orelse "" else "";

    if (numbers) {
        const text = if (choices_on) form.text("number_choices") orelse "" else "";

        set.choices = try settings.lines_of(arena, text);
        set.labels = &.{};
    }
}

/// The shape a text must have: a preset and a pattern, both off with the box.
fn read_shape(form: *const Form, kind: Kind, field: *FieldDef) void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(form.len <= admin.form_pairs_max);

    var set = &field.options;
    const on = kind.has.pattern and form.get("limit_pattern") != null;
    const wanted = form.text("preset") orelse "any";

    set.preset = if (on) std.meta.stringToEnum(Preset, wanted) orelse .any else .any;
    set.pattern = if (on) form.text("pattern") orelse "" else "";
    set.messages.pattern = if (on) form.text("pattern_message") orelse "" else "";
}

/// What a slug, an email, a url and a reference keep out, each a list with a message.
fn read_lists(
    arena: std.mem.Allocator,
    form: *const Form,
    kind: Kind,
    field: *FieldDef,
) Error!void {
    std.debug.assert(std.mem.eql(u8, kind.id, field.kind));
    std.debug.assert(form.len <= admin.form_pairs_max);

    var set = &field.options;
    const is_slug = std.mem.eql(u8, kind.id, "slug");
    const is_email = std.mem.eql(u8, kind.id, "email");
    const is_url = std.mem.eql(u8, kind.id, "url");
    const reserved_on = is_slug and form.get("limit_reserved") != null;
    const domains_on = is_email and form.get("limit_domains") != null;
    const schemes_on = is_url and form.get("limit_schemes") != null;
    const hosts_on = is_url and form.get("limit_hosts") != null;
    const reserved = if (reserved_on) form.text("reserved") orelse "" else "";
    const domains = if (domains_on) form.text("domains") orelse "" else "";
    const hosts = if (hosts_on) form.text("hosts") orelse "" else "";

    set.slug.reserved = try settings.lines_of(arena, reserved);
    set.messages.reserved = if (reserved_on) form.text("reserved_message") orelse "" else "";
    set.email.domains = try settings.lines_of(arena, domains);
    set.messages.domain = if (domains_on) form.text("domain_message") orelse "" else "";
    set.url.schemes = if (schemes_on) try settings.values_of(arena, form, "schemes") else &.{};
    set.messages.scheme = if (schemes_on) form.text("scheme_message") orelse "" else "";
    set.url.hosts = try settings.lines_of(arena, hosts);
    set.messages.host = if (hosts_on) form.text("host_message") orelse "" else "";
    const is_reference = std.mem.eql(u8, kind.id, "reference");

    set.reference.live_only = is_reference and form.get("live_only") != null;
}

/// A range bound: a number, or for a span of days the day's first millisecond (the
/// earliest allowed) or its last (the latest allowed).
fn bound_of(form: *const Form, kind: Kind, name: []const u8, last: bool) ?f64 {
    std.debug.assert(kind.has.range);
    std.debug.assert(name.len > 0);

    if (!kind.has.dates) {
        return number_of(form, name);
    }

    const text = form.text(name) orelse return null;
    const start = time.parse_date(text) orelse return null;
    const ms = if (last) start + day_ms - 1 else start;

    return @floatFromInt(ms);
}

fn read_media(
    arena: std.mem.Allocator,
    form: *const Form,
    media: *model.field.options.Media,
    messages: *model.field.options.Messages,
) Error!void {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(model.field.options.media_types.len > 0);

    const size_on = form.get("limit_size") != null;
    const types_on = form.get("limit_types") != null;
    const dimensions_on = form.get("limit_dimensions") != null;

    media.size_min = if (size_on) size_of(form, "size_min") else null;
    media.size_max = if (size_on) size_of(form, "size_max") else null;
    messages.size = if (size_on) form.text("size_message") orelse "" else "";
    media.types = if (types_on) try settings.values_of(arena, form, "media_types") else &.{};
    messages.types = if (types_on) form.text("types_message") orelse "" else "";
    media.width_min = if (dimensions_on) count_of(form, "width_min") else null;
    media.width_max = if (dimensions_on) count_of(form, "width_max") else null;
    media.height_min = if (dimensions_on) count_of(form, "height_min") else null;
    media.height_max = if (dimensions_on) count_of(form, "height_max") else null;
    messages.dimensions = if (dimensions_on) form.text("dimensions_message") orelse "" else "";
    media.create = form.get("media_create") != null;
    media.link = form.get("media_link") != null;
}

/// A file size as the number typed times its unit (`<name>_unit`: b, kb, mb).
fn size_of(form: *const Form, name: []const u8) ?u64 {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    var unit_name: [32]u8 = undefined;
    const unit_key = std.fmt.bufPrint(&unit_name, "{s}_unit", .{name}) catch return null;
    const amount = number_of(form, name) orelse return null;
    const unit = form.text(unit_key) orelse "b";
    const factor: u64 = if (std.mem.eql(u8, unit, "mb"))
        mib
    else if (std.mem.eql(u8, unit, "kb"))
        kib
    else
        1;

    if (amount < 0 or amount > 1 << 40) {
        return null;
    }

    const bytes: u64 = @intFromFloat(@round(amount));

    return bytes * factor;
}

pub fn count_of(form: *const Form, name: []const u8) ?u32 {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    const text = form.text(name) orelse return null;

    return std.fmt.parseInt(u32, text, 10) catch null;
}

pub fn number_of(form: *const Form, name: []const u8) ?f64 {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    const text = form.text(name) orelse return null;

    const number = std.fmt.parseFloat(f64, text) catch return null;
    return if (std.math.isFinite(number)) number else null;
}

test "a field form becomes a definition: rules only while ticked, sizes in bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const form = Form.parse(arena, "label=SKU&required=1&unique=1&limit_length=1&min_len=2" ++
        "&max_len=12&length_message=Two+to+twelve&help=As+printed&default=x&limit_pattern=1" ++
        "&preset=uppercase&pattern=SKU-%23%23%23%23&placeholder=SKU-0000").?;
    const sku = try field_of(arena, &form, .{ .name = "", .label = "", .kind = "string" });
    try std.testing.expectEqualStrings("sku", sku.name);
    try std.testing.expect(sku.required and sku.unique);
    try std.testing.expectEqual(@as(u32, 2), sku.options.min_len.?);
    try std.testing.expectEqual(@as(u32, 12), sku.options.max_len.?);
    try std.testing.expectEqualStrings("Two to twelve", sku.options.messages.length);
    try std.testing.expectEqualStrings("As printed", sku.help);
    try std.testing.expectEqualStrings("x", sku.default);
    try std.testing.expectEqual(Preset.uppercase, sku.options.preset);
    try std.testing.expectEqualStrings("SKU-####", sku.options.pattern);
    try std.testing.expectEqualStrings("SKU-0000", sku.options.placeholder);

    const off = Form.parse(arena, "label=SKU&min_len=2&pattern=x").?;
    const loose = try field_of(arena, &off, sku);
    try std.testing.expect(loose.options.min_len == null);
    try std.testing.expectEqual(@as(usize, 0), loose.options.messages.length.len);
    try std.testing.expect(!loose.unique);
    try std.testing.expectEqual(@as(usize, 0), loose.options.pattern.len);

    const dated = Form.parse(arena, "label=When&limit_range=1&min=1970-01-02&max=1970-01-02" ++
        "&date_format=date&from_now=1&default_now=1&default=1970-01-02").?;
    const when = try field_of(arena, &dated, .{ .name = "", .label = "", .kind = "datetime" });
    try std.testing.expectEqual(@as(f64, 86_400_000), when.options.min.?);
    try std.testing.expectEqual(@as(f64, 2 * 86_400_000 - 1), when.options.max.?);
    try std.testing.expectEqual(model.field.options.DateFormat.date, when.options.date.format);
    try std.testing.expect(when.options.date.from_now);
    try std.testing.expectEqualStrings("now", when.default);

    const filed = Form.parse(arena, "label=Cover&limit_size=1&size_max=2&size_max_unit=mb" ++
        "&limit_types=1&media_types=image&media_types=video&limit_dimensions=1&width_min=800" ++
        "&media_link=1").?;
    const cover = try field_of(arena, &filed, .{ .name = "", .label = "", .kind = "media" });
    try std.testing.expectEqual(@as(u64, 2 * mib), cover.options.media.size_max.?);
    try std.testing.expect(cover.options.media.size_min == null);
    try std.testing.expectEqual(@as(usize, 2), cover.options.media.types.len);
    try std.testing.expectEqual(@as(u32, 800), cover.options.media.width_min.?);
    try std.testing.expect(!cover.options.media.create and cover.options.media.link);
}

test "lists, listed numbers and the number of values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tags = Form.parse(arena, "label=Tags&many=1&limit_items=1&items_min=1&items_max=5" ++
        "&distinct=1&items_message=One+to+five").?;
    const tagged = try field_of(arena, &tags, .{ .name = "", .label = "", .kind = "string" });
    try std.testing.expectEqual(@as(u32, 5), tagged.options.items_max.?);
    try std.testing.expect(tagged.options.distinct);
    try std.testing.expectEqualStrings("One to five", tagged.options.messages.items);

    const sizes = Form.parse(arena, "label=Size&limit_choices=1&number_choices=1%0A2%0A5").?;
    const sized = try field_of(arena, &sizes, .{ .name = "", .label = "", .kind = "integer" });
    try std.testing.expectEqual(@as(usize, 3), sized.options.choices.len);
    try std.testing.expectEqualStrings("5", sized.options.choices[2]);

    const link = Form.parse(arena, "label=Site&limit_schemes=1&schemes=https&schemes=mailto" ++
        "&limit_hosts=1&hosts=a.io%0Ab.io&host_message=Ours+only").?;
    const site = try field_of(arena, &link, .{ .name = "", .label = "", .kind = "url" });
    try std.testing.expectEqual(@as(usize, 2), site.options.url.schemes.len);
    try std.testing.expectEqualStrings("b.io", site.options.url.hosts[1]);
    try std.testing.expectEqualStrings("Ours only", site.options.messages.host);

    const mail = Form.parse(arena, "label=Mail&limit_domains=1&domains=publr.dev&lowercase=1").?;
    const mailed = try field_of(arena, &mail, .{ .name = "", .label = "", .kind = "email" });
    try std.testing.expectEqualStrings("publr.dev", mailed.options.email.domains[0]);
    try std.testing.expect(mailed.options.email.lowercase);

    const path = Form.parse(arena, "label=Slug&limit_reserved=1&reserved=admin%0Aapi" ++
        "&lock_on_publish=1").?;
    const slugged = try field_of(arena, &path, .{ .name = "", .label = "", .kind = "slug" });
    try std.testing.expectEqual(@as(usize, 2), slugged.options.slug.reserved.len);
    try std.testing.expect(slugged.options.slug.lock_on_publish);
}

test "non-finite file sizes do not reach integer conversion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    for ([_][]const u8{ "size=nan", "size=inf", "size=-inf", "size=1e999" }) |text| {
        const form = Form.parse(arena_state.allocator(), text).?;
        try std.testing.expect(size_of(&form, "size") == null);
    }
}
