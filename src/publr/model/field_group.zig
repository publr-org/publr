/// Where a field group goes.
pub const Destination = enum { content, taxonomy, settings, component, user, media };

/// What a plugin's location rule decides for: the account or file being edited.
pub const Target = struct {
    destination: Destination,
    id: []const u8,
};

pub const Position = enum { main, sidebar };
pub const Labels = enum { above, beside };
pub const Instructions = enum { below_label, below_input };

/// How a group's fields are laid out in the record form.
pub const Presentation = struct {
    position: Position = .main,
    labels: Labels = .above,
    instructions: Instructions = .below_input,
};

/// Whether a group is on, where it shows (any group of rules matching), and how.
pub const Options = struct {
    active: bool = true,
    location: @import("conditions.zig").Set = &.{},
    presentation: Presentation = .{},
};
