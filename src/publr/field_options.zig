//! What a plugin writes for one field in `record.define`'s `.fields` (and a `.register_fields`
//! group's): `.fields = .{ .title = .{ .validation = .{ .max_len = 80 } } }`. The struct field
//! says the rest (its kind, whether it is required, its words). A part named replaces that
//! part whole: `.options = .{ .number = .{ .unit = "kg" } }` sets the number's unit and keeps
//! the number's other settings at their defaults. Two names are not here: `.fields` (a group
//! or repeater's own fields, the same way) and a dimension's field option, named by the
//! plugin that owns the dimension (`.translatable = .required`).

/// One field's overrides, each optional.
pub const Overrides = struct {
    /// A kind id (`string`, `reference`, a plugin's `geo.point`), when the struct field's type
    /// does not say it.
    kind: []const u8 = "",
    searchable: bool = false,
    /// Lists can filter by it, when its kind filters at all.
    filterable: bool = true,
    /// Lists can order by it; null: as its kind does (numbers, money, dates, times).
    sortable: ?bool = null,
    validation: Validation = .{},
    options: Options = .{},
    visibility: Visibility = .{},
};

/// Who may read a field's value: by default whoever reads its record. A restricted field is
/// read only by the plugin that declares it, people holding one of `roles`, and
/// administrators; a special-category field (health data) only by the plugin and `roles`,
/// never by administrators or agents, and never in views, exports, search or emails.
pub const Visibility = struct {
    restricted: bool = false,
    special: bool = false,
    /// The roles that read it besides its plugin.
    roles: []const []const u8 = &.{},
};

/// What a value must be for a write to go through.
pub const Validation = struct {
    required: bool = false,
    /// No two records of the type may hold the same value; a text value held once.
    unique: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    min_len: ?u32 = null,
    max_len: ?u32 = null,
    /// How many values a list holds, and whether every value must differ.
    items_min: ?u32 = null,
    items_max: ?u32 = null,
    distinct: bool = false,
    /// A shape the text must have: a preset, or a pattern of `*` `?` `#` `@`.
    preset: Preset = .any,
    pattern: []const u8 = "",
    words_min: ?u32 = null,
    words_max: ?u32 = null,
    messages: Messages = .{},
    /// The rules as the field shows them beside its help, replacing the line its kind writes;
    /// `{max_len}` and the other bounds are filled in.
    hint: []const u8 = "",
    date: DateRule = .{},
    slug: SlugRule = .{},
    email: EmailRule = .{},
    url: UrlRule = .{},
    reference: ReferenceRule = .{},
    media: MediaRule = .{},
};

/// The message an editor sees when a value breaks the matching rule; the built-in one when
/// empty.
pub const Messages = struct {
    length: []const u8 = "",
    range: []const u8 = "",
    size: []const u8 = "",
    types: []const u8 = "",
    dimensions: []const u8 = "",
    items: []const u8 = "",
    pattern: []const u8 = "",
    words: []const u8 = "",
    domain: []const u8 = "",
    scheme: []const u8 = "",
    host: []const u8 = "",
    reserved: []const u8 = "",
    choices: []const u8 = "",
};

/// A shape a text must have, short of writing a pattern.
pub const Preset = enum {
    any,
    digits,
    letters,
    alphanumeric,
    no_spaces,
    lowercase,
    uppercase,
    phone,
};

pub const DateRule = struct {
    /// Refuse moments before the day the record is written.
    from_now: bool = false,
};

pub const SlugRule = struct {
    /// Slugs the site keeps for itself; refused on any record.
    reserved: []const []const u8 = &.{},
    /// A slug someone gave (typed, sent) that another record holds is refused as a conflict
    /// instead of numbered (`-2`). Derived slugs are numbered either way.
    refuse_taken: bool = false,
};

pub const EmailRule = struct {
    /// Empty accepts any domain; else only addresses at these.
    domains: []const []const u8 = &.{},
};

pub const UrlRule = struct {
    /// Empty accepts http and https; else only these: `http`, `https`, `mailto`, `tel`.
    schemes: []const []const u8 = &.{},
    /// Empty accepts any host; else only these.
    hosts: []const []const u8 = &.{},
};

pub const ReferenceRule = struct {
    /// Only records that are live may be pointed at.
    live_only: bool = false,
    /// Only publicly readable record types may be selected.
    public_only: bool = false,
};

/// The file a media field points at: sizes in bytes, dimensions in pixels; a null bound is
/// no bound.
pub const MediaRule = struct {
    size_min: ?u64 = null,
    size_max: ?u64 = null,
    /// Empty accepts any file; else only these families: `image`, `video`, `audio`, `pdf`,
    /// `document`, `spreadsheet`, `presentation`, `text`, `code`, `archive`, `font`.
    types: []const []const u8 = &.{},
    width_min: ?u32 = null,
    width_max: ?u32 = null,
    height_min: ?u32 = null,
    height_max: ?u32 = null,
};

/// How a field is shown and edited.
pub const Options = struct {
    /// How far a number's control steps.
    step: ?f64 = null,
    /// A select's values, or the only values a number may take.
    choices: []const []const u8 = &.{},
    /// What the choices read as, one per choice; empty when the values are the labels.
    labels: []const []const u8 = &.{},
    /// The field a slug is made from.
    source: []const u8 = "",
    /// The record types a reference may point at, by name; empty for any record type. A
    /// virtual field names the one type its records are of.
    to: []const []const u8 = &.{},
    /// A virtual field: which kind (`referenced_by`), and the reference field of the `to`
    /// type that points here.
    virtual: []const u8 = "",
    via: []const u8 = "",
    /// The taxonomy a terms field assigns from, by name.
    taxonomy: []const u8 = "",
    rows: ?u32 = null,
    placeholder: []const u8 = "",
    text: Text = .{},
    richtext: RichText = .{},
    date: Date = .{},
    slug: Slug = .{},
    email: Email = .{},
    boolean: Boolean = .{},
    number: Number = .{},
    select: Select = .{},
    reference: Reference = .{},
    container: Container = .{},
    media: Media = .{},
    provider: Provider = .{},
};

/// How a date and time field is shown and posted: a moment, or a day alone.
pub const DateFormat = enum { datetime, date };

pub const Date = struct {
    format: DateFormat = .datetime,
};

pub const TextFormat = enum { plain, markdown };

pub const Text = struct {
    format: TextFormat = .plain,
};

pub const RichFormat = enum { bold, italic, link };

pub const RichText = struct {
    /// The formatting its editor offers; null for all of it, empty for plain paragraphs.
    formats: ?[]const RichFormat = null,
};

pub const Slug = struct {
    /// Once the record is live the slug stays as it is, whatever the source does.
    lock_on_publish: bool = false,
};

pub const Email = struct {
    lowercase: bool = false,
};

pub const BooleanControl = enum { toggle, checkbox, radio };

pub const Boolean = struct {
    true_label: []const u8 = "",
    false_label: []const u8 = "",
    control: BooleanControl = .toggle,
};

pub const NumberControl = enum { input, slider, rating };

pub const Number = struct {
    /// Shown beside the input: `kg`, `$`, `%`.
    unit: []const u8 = "",
    unit_after: bool = true,
    /// How many decimal places the input steps by; null for any.
    decimals: ?u32 = null,
    control: NumberControl = .input,
};

pub const SelectControl = enum { dropdown, list, buttons };

pub const Select = struct {
    /// A dropdown, or the choices laid out as radios (one value) or checkboxes (many).
    control: SelectControl = .dropdown,
};

/// What purging a record a reference points at does to the reference.
pub const OnDelete = enum { keep, block, clear };

pub const Reference = struct {
    create: bool = true,
    link: bool = true,
    on_delete: OnDelete = .keep,
};

pub const Container = struct {
    collapsed: bool = false,
    /// The child whose value names a repeater item in its header.
    label_field: []const u8 = "",
    add_label: []const u8 = "",
};

/// The contract whose registered providers a provider field names.
pub const Provider = struct {
    contract: []const u8 = "",
};

/// What a media field's editor offers: creating new files, linking existing ones.
pub const Media = struct {
    create: bool = true,
    link: bool = true,
};
