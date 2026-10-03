const std = @import("std");
const kinds = @import("kinds.zig");
const defaults = @import("defaults.zig");

pub const options = @import("field/options.zig");
pub const conditions = @import("conditions.zig");
pub const presets = @import("field/presets.zig");
pub const pattern = @import("field/pattern.zig");

pub const name_len_max: u32 = 64;
pub const label_len_max: u32 = 128;
pub const help_len_max: u32 = 255;
pub const fields_max: u32 = 64;
pub const depth_max: u32 = 3;
pub const choices_max: u32 = 256;
pub const targets_max: u32 = 64;

pub const Column = enum { text, int, real, ref, long };

pub const Options = options.Options;

pub const Def = struct {
    name: []const u8,
    label: []const u8,
    /// A kind id from the registry (`string`, `reference`, a plugin's `geo.point`).
    kind: []const u8,
    conditions: conditions.Set = &.{},
    required: bool = false,
    /// No two records of the type may hold the same value; a text value held once.
    unique: bool = false,
    searchable: bool = false,
    /// Declared in code by the type's owner: shown, never edited or removed by hand.
    locked: bool = false,
    many: bool = false,
    /// Shown under the control in the record form.
    help: []const u8 = "",
    /// What a new record starts with, as the text its kind's control posts; empty for none.
    default: []const u8 = "",
    options: Options = .{},
    fields: []const Def = &.{},
};

pub const Problem = struct { path: []const u8, message: []const u8 };

pub const problems_max: u32 = 64;
pub const path_len_max: u32 = 256;

pub const Problems = struct {
    items: [problems_max]Problem = undefined,
    paths: [problems_max][path_len_max]u8 = undefined,
    len: u32 = 0,
    overflowed: bool = false,

    pub fn add(problems: *Problems, path: []const u8, message: []const u8) void {
        std.debug.assert(message.len > 0);
        std.debug.assert(problems.len <= problems_max);

        if (problems.len == problems_max) {
            problems.overflowed = true;

            return;
        }

        const kept = @min(path.len, path_len_max);
        const slot = &problems.paths[problems.len];

        @memcpy(slot[0..kept], path[0..kept]);
        problems.items[problems.len] = .{ .path = slot[0..kept], .message = message };
        problems.len += 1;
    }

    pub fn slice(problems: *const Problems) []const Problem {
        std.debug.assert(problems.len <= problems_max);
        std.debug.assert(problems.items.len == problems_max);

        return problems.items[0..problems.len];
    }

    pub fn is_empty(problems: *const Problems) bool {
        std.debug.assert(problems.len <= problems_max);
        std.debug.assert(!problems.overflowed or problems.len == problems_max);

        return problems.len == 0;
    }
};

/// The two containers are the core's: a plugin kind always holds values of its own.
pub fn is_container(kind: []const u8) bool {
    if (kind.len > kinds.string_len_max) {
        return false;
    }

    std.debug.assert(depth_max > 0);

    return is_group(kind) or is_repeater(kind);
}

pub fn is_layout(kind: []const u8) bool {
    std.debug.assert(kind.len <= kinds.string_len_max);
    return std.mem.eql(u8, kind, "message") or std.mem.eql(u8, kind, "tab") or
        std.mem.eql(u8, kind, "accordion");
}

pub fn is_leaf(kind: []const u8) bool {
    const leaf = !is_container(kind);

    std.debug.assert(leaf or is_container(kind));
    std.debug.assert(!leaf or !is_group(kind));

    return leaf;
}

/// A money field: an amount per currency, `{ "GBP": 850 }`, each in minor units.
pub fn is_money(kind: []const u8) bool {
    std.debug.assert(kind.len <= 64 << 10);

    return std.mem.eql(u8, kind, "money");
}

pub fn is_group(kind: []const u8) bool {
    if (kind.len > kinds.string_len_max) {
        return false;
    }

    std.debug.assert(depth_max > 0);

    return std.mem.eql(u8, kind, "group") or std.mem.eql(u8, kind, "link") or
        std.mem.eql(u8, kind, "location");
}

pub fn is_repeater(kind: []const u8) bool {
    if (kind.len > kinds.string_len_max) {
        return false;
    }

    std.debug.assert(depth_max > 0);

    return std.mem.eql(u8, kind, "repeater");
}

pub fn is_slug(kind: []const u8) bool {
    if (kind.len > kinds.string_len_max) {
        return false;
    }

    std.debug.assert(depth_max > 0);

    return std.mem.eql(u8, kind, "slug");
}

pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max) {
        return false;
    }

    for (name, 0..) |char, index| {
        const lower = char >= 'a' and char <= 'z';
        const digit = char >= '0' and char <= '9';

        if (!(lower or char == '_' or (digit and index > 0))) {
            return false;
        }
    }

    std.debug.assert(name.len <= name_len_max);

    return name[0] >= 'a' and name[0] <= 'z';
}

pub fn validate_defs(
    known: []const kinds.Kind,
    defs: []const Def,
    depth: u32,
    problems: *Problems,
) void {
    validate_defs_in(known, defs, depth, false, problems);
}

fn validate_defs_in(
    known: []const kinds.Kind,
    defs: []const Def,
    depth: u32,
    inside_repeater: bool,
    problems: *Problems,
) void {
    std.debug.assert(depth <= depth_max);
    std.debug.assert(problems.len <= problems_max);

    if (defs.len > fields_max) {
        problems.add("fields", "too many fields");

        return;
    }

    conditions.validate_fields(defs, problems);

    for (defs, 0..) |def, index| {
        validate_def(known, def, depth, inside_repeater, problems);

        for (defs[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, def.name)) {
                problems.add(def.name, "duplicate field name");
            }
        }
    }
}

fn validate_def(
    known: []const kinds.Kind,
    def: Def,
    depth: u32,
    inside_repeater: bool,
    problems: *Problems,
) void {
    std.debug.assert(depth <= depth_max);
    std.debug.assert(problems.len <= problems_max);

    if (!valid_name(def.name)) {
        problems.add(def.name, "field name must be [a-z][a-z0-9_]*, up to 64 characters");
        return;
    }

    if (def.label.len == 0 or def.label.len > label_len_max) {
        problems.add(def.name, "label must be 1 to 128 characters");
    }

    const kind = kinds.find(known, def.kind) orelse {
        problems.add(def.name, "unknown kind");

        return;
    };

    if (is_layout(def.kind) and (depth > 0 or def.required or def.conditions.len > 0)) {
        problems.add(
            def.name,
            "layout elements belong at the top level and have no validation or conditions",
        );
    }

    validate_kind_rules(kind, def, inside_repeater, problems);

    if (is_leaf(def.kind)) {
        if (def.fields.len != 0) {
            problems.add(def.name, "only group and repeater have child fields");
        }

        return;
    }

    if (depth == depth_max) {
        problems.add(def.name, "fields nest too deep");

        return;
    }

    const repeated = inside_repeater or is_repeater(def.kind);

    validate_defs_in(known, def.fields, depth + 1, repeated, problems);
}

/// What the kind's descriptor says a field of it may be and must carry.
fn validate_kind_rules(
    kind: kinds.Kind,
    def: Def,
    inside_repeater: bool,
    problems: *Problems,
) void {
    std.debug.assert(std.mem.eql(u8, kind.id, def.kind));
    std.debug.assert(problems.len <= problems_max);

    if (def.searchable and !kind.searchable_allowed) {
        problems.add(def.name, "this kind cannot be searchable");
    }

    if (def.many and !kind.many_allowed) {
        problems.add(def.name, "this kind cannot hold many values");
    }

    if (inside_repeater and (is_repeater(def.kind) or (def.many and kind.storage == .ref))) {
        problems.add(def.name, "a repeater cannot contain another repeated field");
    }

    const choices = def.options.choices.len;

    if (kind.control == .select and kind.has.choices and choices == 0) {
        problems.add(def.name, "needs at least one choice");
    }

    if (choices > choices_max or (!kind.has.choices and choices > 0)) {
        problems.add(def.name, "up to 256 choices, on a select or a number field");
    }

    if (def.options.labels.len != 0 and def.options.labels.len != choices) {
        problems.add(def.name, "one label per choice, or none");
    }

    if (choices <= choices_max and kind.has.choices and kind.control != .select) {
        validate_number_choices(def, problems);
    }

    if (kind.has.target and def.options.to.len > targets_max) {
        problems.add(def.name, "too many target types");
    }

    if (kind.has.taxonomy and !valid_name(def.options.taxonomy)) {
        problems.add(def.name, "a terms field names the taxonomy it assigns from");
    }

    if (!kind.has.taxonomy and def.options.taxonomy.len > 0) {
        problems.add(def.name, "only a terms field names a taxonomy");
    }

    if (def.unique and (!kind.unique_allowed or def.many)) {
        problems.add(def.name, "only a single text, email or url field can be unique");
    }

    if (def.help.len > help_len_max) {
        problems.add(def.name, "help text must be up to 255 characters");
    }

    validate_default(kind, def, problems);
    validate_bounds(def, problems);
    validate_shape(kind, def, problems);
    validate_lists(kind, def, problems);

    if (kind.has.media) {
        validate_media(def, problems);
    }
}

fn validate_number_choices(def: Def, problems: *Problems) void {
    std.debug.assert(def.options.choices.len <= choices_max);
    std.debug.assert(problems.len <= problems_max);

    for (def.options.choices) |choice| {
        const number = std.fmt.parseFloat(f64, choice) catch {
            problems.add(def.name, "every listed value must be a number");

            return;
        };

        if (std.math.isNan(number) or std.math.isInf(number)) {
            problems.add(def.name, "every listed value must be a number");

            return;
        }
    }
}

/// The pattern, the words, the container's label field and the kind groups' own lists.
fn validate_shape(kind: kinds.Kind, def: Def, problems: *Problems) void {
    std.debug.assert(std.mem.eql(u8, kind.id, def.kind));
    std.debug.assert(problems.len <= problems_max);

    const set = def.options;

    if (set.pattern.len > options.pattern_len_max) {
        problems.add(def.name, "a pattern must be up to 255 characters");
    }

    if ((set.pattern.len > 0 or set.preset != .any) and !kind.has.pattern) {
        problems.add(def.name, "only a text field takes a pattern");
    }

    if (!options.ordered(u32, set.words_min, set.words_max)) {
        problems.add(def.name, "minimum word count is above the maximum");
    }

    if (set.number.decimals != null and set.number.decimals.? > options.decimals_max) {
        problems.add(def.name, "up to 10 decimal places");
    }

    for (set.slug.reserved) |reserved| {
        if (!kinds.valid_slug(reserved)) {
            problems.add(def.name, "a reserved slug must be [a-z0-9] and hyphens");

            break;
        }
    }

    for (set.url.schemes) |scheme| {
        if (!options.valid_scheme(scheme)) {
            problems.add(def.name, "unknown url scheme");

            break;
        }
    }

    if (def.fields.len > fields_max) {
        problems.add(def.name, "too many child fields");
        return;
    }

    if (set.container.label_field.len > 0 and find(def.fields, set.container.label_field) == null) {
        problems.add(def.name, "the label field must be one of the fields inside");
    }
}

/// A list's bounds, on a field that is a list.
fn validate_lists(kind: kinds.Kind, def: Def, problems: *Problems) void {
    std.debug.assert(std.mem.eql(u8, kind.id, def.kind));
    std.debug.assert(problems.len <= problems_max);

    const set = def.options;
    const listed = def.many or is_repeater(def.kind);
    const bounded = set.items_min != null or set.items_max != null;

    if ((bounded or set.distinct) and !listed) {
        problems.add(def.name, "only a list of values has a number of items");
    }

    if (!options.ordered(u32, set.items_min, set.items_max)) {
        problems.add(def.name, "minimum number of items is above the maximum");
    }

    if (set.items_max != null and set.items_max.? > validate_items_max) {
        problems.add(def.name, "at most 1000 items");
    }

    const lists = [_][]const []const u8{
        set.slug.reserved,
        set.email.domains,
        set.url.schemes,
        set.url.hosts,
    };

    for (lists) |list| {
        if (list.len > options.list_max) {
            problems.add(def.name, "up to 64 entries in a list option");

            return;
        }
    }
}

pub const validate_items_max: u32 = 1000;

fn find(fields: []const Def, name: []const u8) ?*const Def {
    std.debug.assert(fields.len <= fields_max);
    std.debug.assert(name.len > 0);

    for (fields) |*candidate| {
        if (std.mem.eql(u8, candidate.name, name)) {
            return candidate;
        }
    }

    return null;
}

fn validate_default(kind: kinds.Kind, def: Def, problems: *Problems) void {
    std.debug.assert(std.mem.eql(u8, kind.id, def.kind));
    std.debug.assert(problems.len <= problems_max);

    if (def.default.len == 0) {
        return;
    }

    if (!kind.default_allowed) {
        problems.add(def.name, "this kind takes no default value");
    } else if (def.unique) {
        problems.add(def.name, "a unique field takes no default value");
    } else if (def.default.len > defaults.default_len_max or !defaults.fits(kind, def)) {
        problems.add(def.name, "the default value does not fit the kind");
    }
}

/// A lower bound above its upper bound can never hold; a message must fit its box.
fn validate_bounds(def: Def, problems: *Problems) void {
    std.debug.assert(def.name.len <= name_len_max or def.name.len == 0);
    std.debug.assert(problems.len <= problems_max);

    const set = def.options;
    const messages = [_][]const u8{
        set.messages.length,     set.messages.range,  set.messages.size,    set.messages.types,
        set.messages.dimensions, set.messages.items,  set.messages.pattern, set.messages.words,
        set.messages.domain,     set.messages.scheme, set.messages.host,    set.messages.reserved,
        set.messages.choices,
    };

    if (!options.ordered(u32, set.min_len, set.max_len)) {
        problems.add(def.name, "minimum length is above the maximum");
    }

    for ([_]?f64{ set.min, set.max }) |bound| {
        if (bound) |number| {
            if (!std.math.isFinite(number)) problems.add(def.name, "bounds must be finite");
        }
    }

    if (!options.ordered(f64, set.min, set.max)) {
        problems.add(def.name, "minimum is above the maximum");
    }

    for (messages) |message| {
        if (message.len > options.message_len_max) {
            problems.add(def.name, "a custom error message must be up to 255 characters");

            return;
        }
    }
}

fn validate_media(def: Def, problems: *Problems) void {
    std.debug.assert(def.name.len <= name_len_max or def.name.len == 0);
    std.debug.assert(problems.len <= problems_max);

    const media = def.options.media;

    if (media.types.len > options.media_types_max) {
        problems.add(def.name, "too many file types");
    } else {
        for (media.types) |media_type| {
            if (!options.valid_media_type(media_type)) {
                problems.add(def.name, "unknown file type");
            }
        }
    }

    if (!options.ordered(u64, media.size_min, media.size_max)) {
        problems.add(def.name, "minimum file size is above the maximum");
    }

    const width_ok = options.ordered(u32, media.width_min, media.width_max);
    const height_ok = options.ordered(u32, media.height_min, media.height_max);

    if (!width_ok or !height_ok) {
        problems.add(def.name, "minimum dimension is above the maximum");
    }

    if (!media.create and !media.link) {
        problems.add(def.name, "a media field must allow creating files, linking them, or both");
    }
}

test "containers and names" {
    try std.testing.expect(!is_leaf("repeater"));
    try std.testing.expect(is_container("group"));
    try std.testing.expect(is_leaf("string"));
    try std.testing.expect(is_leaf("geo.point"));
    try std.testing.expect(is_slug("slug"));
    try std.testing.expect(valid_name("title"));
    try std.testing.expect(valid_name("seo_title2"));
    try std.testing.expect(!valid_name("Title"));
    try std.testing.expect(!valid_name("2nd"));
    try std.testing.expect(!valid_name(""));
}

test "definitions: duplicates, select without choices, unknown kind, nesting depth" {
    var problems: Problems = .{};
    const good = [_]Def{
        .{ .name = "title", .label = "Title", .kind = "string", .required = true },
        .{
            .name = "tags",
            .label = "Tags",
            .kind = "reference",
            .many = true,
            .options = .{ .to = &.{"tag"} },
        },
        .{ .name = "gallery", .label = "Gallery", .kind = "repeater", .fields = &.{
            .{ .name = "image", .label = "Image", .kind = "media" },
            .{ .name = "caption", .label = "Caption", .kind = "string" },
        } },
    };
    validate_defs(&kinds.core, &good, 0, &problems);
    try std.testing.expect(problems.is_empty());

    var bad_problems: Problems = .{};
    const bad = [_]Def{
        .{ .name = "title", .label = "Title", .kind = "string" },
        .{ .name = "title", .label = "Again", .kind = "text" },
        .{ .name = "kind", .label = "Kind", .kind = "select" },
        .{
            .name = "author",
            .label = "Author",
            .kind = "reference",
            .options = .{ .to = &.{"x"} },
        },
        .{ .name = "many_slug", .label = "Many", .kind = "slug", .many = true },
        .{ .name = "views", .label = "Views", .kind = "integer", .searchable = true },
        .{ .name = "point", .label = "Point", .kind = "geo.point" },
        .{ .name = "faq", .label = "FAQ", .kind = "repeater", .fields = &.{
            .{
                .name = "links",
                .label = "Links",
                .kind = "reference",
                .many = true,
                .options = .{ .to = &.{"x"} },
            },
        } },
    };
    validate_defs(&kinds.core, &bad, 0, &bad_problems);
    try std.testing.expectEqual(@as(u32, 6), bad_problems.len);
    try std.testing.expectEqualStrings("unknown kind", bad_problems.items[4].message);

    var deep_problems: Problems = .{};
    const level4 = [_]Def{.{ .name = "v", .label = "V", .kind = "string" }};
    const level3 = [_]Def{.{ .name = "z", .label = "Z", .kind = "group", .fields = &level4 }};
    const level2 = [_]Def{.{ .name = "y", .label = "Y", .kind = "group", .fields = &level3 }};
    const level1 = [_]Def{.{ .name = "x", .label = "X", .kind = "group", .fields = &level2 }};
    const deep = [_]Def{.{ .name = "w", .label = "W", .kind = "group", .fields = &level1 }};
    validate_defs(&kinds.core, &deep, 0, &deep_problems);
    try std.testing.expect(!deep_problems.is_empty());
}

test "unique, help, default and the kind's own option rules" {
    var problems: Problems = .{};
    const good = [_]Def{
        .{ .name = "sku", .label = "SKU", .kind = "string", .unique = true, .help = "As printed" },
        .{ .name = "title", .label = "Title", .kind = "string", .default = "Untitled" },
        .{
            .name = "cover",
            .label = "Cover",
            .kind = "media",
            .options = .{ .media = .{ .types = &.{"image"}, .width_min = 100, .size_max = 1000 } },
        },
    };
    validate_defs(&kinds.core, &good, 0, &problems);
    try std.testing.expect(problems.is_empty());

    var bad_problems: Problems = .{};
    const bad = [_]Def{
        .{ .name = "views", .label = "Views", .kind = "number", .unique = true },
        .{ .name = "tags", .label = "Tags", .kind = "string", .many = true, .unique = true },
        .{ .name = "link", .label = "Link", .kind = "reference", .default = "x" },
        .{ .name = "code", .label = "Code", .kind = "string", .unique = true, .default = "x" },
        .{ .name = "count", .label = "Count", .kind = "integer", .default = "many" },
        .{
            .name = "short",
            .label = "Short",
            .kind = "string",
            .options = .{ .min_len = 5, .max_len = 2 },
        },
        .{ .name = "cover", .label = "Cover", .kind = "media", .options = .{ .media = .{
            .types = &.{"font"},
            .create = false,
            .link = false,
        } } },
    };
    validate_defs(&kinds.core, &bad, 0, &bad_problems);
    try std.testing.expectEqual(@as(u32, 8), bad_problems.len);
    try std.testing.expectEqualStrings("unknown file type", bad_problems.items[6].message);
}

test "shapes, lists and the kind groups' own option rules" {
    var problems: Problems = .{};
    const good = [_]Def{
        .{ .name = "code", .label = "Code", .kind = "string", .options = .{
            .pattern = "SKU-####",
        } },
        .{ .name = "tags", .label = "Tags", .kind = "string", .many = true, .options = .{
            .items_min = 1,
            .items_max = 5,
            .distinct = true,
        } },
        .{ .name = "size", .label = "Size", .kind = "integer", .options = .{
            .choices = &.{ "1", "2" },
        } },
        .{ .name = "faq", .label = "FAQ", .kind = "repeater", .options = .{
            .items_max = 10,
            .container = .{ .label_field = "question" },
        }, .fields = &.{
            .{ .name = "question", .label = "Question", .kind = "string" },
        } },
        .{ .name = "site", .label = "Site", .kind = "url", .options = .{
            .url = .{ .schemes = &.{"https"} },
        } },
    };
    validate_defs(&kinds.core, &good, 0, &problems);
    try std.testing.expect(problems.is_empty());

    var bad_problems: Problems = .{};
    const bad = [_]Def{
        .{ .name = "views", .label = "Views", .kind = "integer", .options = .{ .pattern = "#" } },
        .{ .name = "one", .label = "One", .kind = "string", .options = .{ .items_max = 3 } },
        .{ .name = "size", .label = "Size", .kind = "integer", .options = .{
            .choices = &.{"big"},
        } },
        .{ .name = "kind", .label = "Kind", .kind = "select", .options = .{
            .choices = &.{ "a", "b" },
            .labels = &.{"A"},
        } },
        .{ .name = "faq", .label = "FAQ", .kind = "repeater", .options = .{
            .container = .{ .label_field = "nope" },
        } },
        .{ .name = "site", .label = "Site", .kind = "url", .options = .{
            .url = .{ .schemes = &.{"ftp"} },
        } },
        .{ .name = "slug", .label = "Slug", .kind = "slug", .options = .{
            .slug = .{ .reserved = &.{"Bad Slug"} },
        } },
    };
    validate_defs(&kinds.core, &bad, 0, &bad_problems);
    try std.testing.expectEqual(@as(u32, 7), bad_problems.len);
}

pub fn contains_kind(defs: []const Def, kind: []const u8) bool {
    std.debug.assert(defs.len <= fields_max);
    std.debug.assert(kind.len > 0);
    const Frame = struct { fields: []const Def, index: u32 = 0 };
    var frames: [depth_max + 1]Frame = undefined;
    frames[0] = .{ .fields = defs };
    var depth: u32 = 0;

    while (true) {
        const frame = &frames[depth];

        if (frame.index == frame.fields.len) {
            if (depth == 0) {
                return false;
            }
            depth -= 1;
            continue;
        }

        const def = frame.fields[frame.index];
        frame.index += 1;

        if (std.mem.eql(u8, def.kind, kind)) {
            return true;
        }

        if (def.fields.len > 0 and depth < depth_max) {
            depth += 1;
            frames[depth] = .{ .fields = def.fields };
        }
    }
}
