//! A field of a content type, a taxonomy or a custom field group, as its definition holds it
//! (`publr.field.Def`), and what a check of a definition finds wrong with its fields.
const field_options = @import("../field_options.zig");
const conditions = @import("conditions.zig");
const written = @import("../../model/field/json.zig");

pub const Options = field_options.Options;
pub const Validation = field_options.Validation;
pub const Visibility = field_options.Visibility;

pub const Def = struct {
    name: []const u8,
    label: []const u8,
    /// A kind id from the registry (`string`, `reference`, a plugin's `geo.point`).
    kind: []const u8,
    conditions: conditions.Set = &.{},
    searchable: bool = false,
    /// Lists can filter by it, when its kind filters at all.
    filterable: bool = true,
    /// Lists can order by it; null: as its kind does (numbers, money, dates, times).
    sortable: ?bool = null,
    /// The dimensions it holds a value per combination of, beside the main one
    /// (`name@language=pl`); `"*"` for every one the site has. How it holds each: listed only
    /// here, an empty value shows the main one; also in `required_in`, every value going live
    /// must be filled; also in `empty_in`, an empty value shows nothing.
    dimensions: []const []const u8 = &.{},
    required_in: []const []const u8 = &.{},
    empty_in: []const []const u8 = &.{},
    /// The dimensions it holds one value for though they would vary a field that says
    /// nothing of them: an A/B test's family, said no to.
    not_in: []const []const u8 = &.{},
    /// What a plugin's code says through another plugin's field option (`.translatable =
    /// .required`): made into `dimensions` above where the plugin's types are applied, by
    /// whichever dimension the site has offers the option; nothing while none does.
    wrapped: []const Wrapped = &.{},
    /// Declared in code by the type's owner: shown, never edited or removed by hand.
    locked: bool = false,
    many: bool = false,
    /// Shown under the control in the record form.
    help: []const u8 = "",
    /// What a new record starts with, as the text its kind's control posts; empty for none.
    default: []const u8 = "",
    /// What a value must be for a write to go through.
    validation: Validation = .{},
    /// How the field is shown and edited.
    options: Options = .{},
    /// Who may read its value.
    visibility: Visibility = .{},
    /// A group's or a repeater's own fields.
    fields: []const Def = &.{},

    pub const publr_form = .fields;

    /// Every member, but `visibility` only when the field is hidden.
    pub fn jsonStringify(def: Def, writer: anytype) !void {
        return written.definition(Def, def, writer);
    }
};

/// One field option of a dimension's owner, as a plugin's field gives it.
pub const Wrapped = struct {
    /// `translatable`.
    option: []const u8,
    /// `required`: one of the values the option takes.
    value: []const u8,
};

/// One thing wrong, at a path into the definition: `fields[2].options.to`.
pub const Problem = struct {
    path: []const u8,
    message: []const u8,
};
