//! The columns plugins add to People (`.register_columns` on `users`) or the media library
//! (`media`) that a person hides: their own choice, else the one administrators made for
//! everyone, else none hidden.
const operation = @import("../../operation.zig");

/// The lists a person picks plugins' columns on.
pub const List = enum { users, media };

pub const Columns = struct {
    pub const name = "user.columns";
    pub const description = "The plugins' columns on People or the media library you hide";
    pub const details =
        \\Any signed-in account, about itself: `hidden` names the columns plugins add to
        \\`list` (`users`, People; `media`, the media library) that it does not show, by
        \\field (`loyalty.points`): its own choice, else the one administrators made for
        \\everyone.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    /// Open, but about the account asking: its example names one.
    pub const example_signed_in = true;
    pub const In = struct {
        list: List = .users,
    };
    pub const Out = struct {
        hidden: []const []const u8,
    };
    pub const example: In = .{};
    pub const field_docs: operation.Docs(In) = .{
        .list = "`users` for People, `media` for the media library",
    };
    pub const example_out: Out = .{
        .hidden = &.{},
    };
    pub const output_docs: operation.Docs(Out) = .{
        .hidden = "The columns not shown, by field",
    };
};

pub const SetColumns = struct {
    pub const name = "user.set_columns";
    pub const description = "Choose which plugins' columns on People or the media library you hide";
    pub const details =
        \\Any signed-in account, for itself: `hidden` names the columns plugins add to `list`
        \\(`users`, People; `media`, the media library) that it does not show, by field.
        \\`for_everyone` (administrators only) makes the choice everyone starts at who made
        \\none.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    /// Open, but about the account asking: its example names one.
    pub const example_signed_in = true;
    pub const In = struct {
        hidden: []const []const u8 = &.{},
        list: List = .users,
        for_everyone: bool = false,
    };
    pub const Out = struct {
        hidden: []const []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .hidden = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{
        .hidden = "Columns plugins add to the list, by field (`loyalty.points`)",
        .list = "`users` for People, `media` for the media library",
        .for_everyone = "Everyone's choice (administrators only)",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .hidden = "The columns not shown now",
    };
};
