//! What a plugin keeps, as pieces: the content types and taxonomies it owns, its internal
//! records, field groups and roles; read, put in the trash, erased or brought back.
const operation = @import("../../operation.zig");

pub const Kind = enum { type, taxonomy, internal, fields, role };

pub const Piece = struct {
    key: []const u8,
    kind: Kind,
    /// As the admin names it: the type's or group's name, the collection's.
    label: []const u8,
    /// Records, terms or internal records it holds, the accounts holding a role; 0 for a
    /// field group.
    count: u32,
    /// Its trash entry when it is in the trash; empty when it is kept where it is.
    trash: []const u8 = "",
};

/// What happens to a piece when its plugin is uninstalled.
pub const Fate = enum { keep, trash, erase };

const example_pieces = [_]Piece{
    .{
        .key = "type:course",
        .kind = .type,
        .label = "Course",
        .count = 12,
    },
    .{
        .key = "internal:enrolments",
        .kind = .internal,
        .label = "enrolments",
        .count = 340,
        .trash = "0190a1b2c3d40001a1b2c3d4",
    },
};

pub const Data = struct {
    pub const name = "plugin.data";
    pub const description = "What data a plugin has: kept where it is, or in the trash";
    pub const details =
        \\Read from the database by owner, so an uninstalled plugin's data is listed too: the
        \\content types it owns (with their records), its taxonomies, the collections of
        \\internal records it keeps, its custom field groups and roles. Each a piece with a
        \\key; a piece in the trash names its entry (`trash`), which `trash restore` brings
        \\back. Uninstalling decides each piece (`plugin remove --trash`); `plugin
        \\erase_data` erases pieces for good.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {
        pieces: []const Piece,
    };
    pub const example: In = .{
        .name = "greeter",
    };
    pub const example_out: Out = .{
        .pieces = &example_pieces,
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The plugin's name",
    };
};

pub const EraseData = struct {
    pub const name = "plugin.erase_data";
    pub const description = "Erase an uninstalled plugin's data for good";
    pub const details =
        \\Each piece named (keys from `plugin data`) is erased: one kept where it is is
        \\deleted with no copy, one in the trash has its entry removed. It cannot be undone.
        \\Only for a plugin that is not installed; a device (an agent) lists it for its
        \\person instead. The activity log keeps who erased which pieces, never the data.
    ;
    pub const kind: operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        name: []const u8,
        pieces: []const []const u8,
    };
    pub const Out = struct {
        /// What went, in words: "Course (12 records), enrolments (340 internal records)".
        erased: []const u8,
    };
    pub const example: In = .{
        .name = "shelf",
        .pieces = &.{"type:shelf.item"},
    };
    pub const example_out: Out = .{
        .erased = "Item (1 record)",
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The plugin's name",
        .pieces = "The keys of the pieces to erase",
    };
};

pub const RestoreData = struct {
    pub const name = "plugin.restore_data";
    pub const description = "Bring pieces of a plugin's data back from the trash";
    pub const details =
        \\Each piece named (keys from `plugin data`, in the trash) comes back as it was. A
        \\content type or taxonomy the plugin made again since it was installed anew gives way
        \\when it is still empty; one holding anything stays, and that piece is refused.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        pieces: []const []const u8,
    };
    pub const Out = struct {
        pieces: []const Piece,
    };
    pub const example: In = .{
        .name = "shelf",
        .pieces = &.{"type:shelf.item"},
    };
    pub const example_out: Out = .{
        .pieces = &example_pieces,
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The plugin's name",
        .pieces = "The keys of the pieces to bring back",
    };
};

/// One uninstalled plugin and what it left.
pub const Left = struct {
    name: []const u8,
    pieces: []const Piece,
    /// The plugin's own trash entry while it is there: `trash restore` reinstalls it.
    trash: []const u8 = "",
};

const example_left = [_]Left{.{
    .name = "greeter",
    .pieces = &example_pieces,
}};

pub const LeftBehind = struct {
    pub const name = "plugin.left_behind";
    pub const description = "Uninstalled plugins whose data is still here";
    pub const details =
        \\Each plugin that is not installed but whose data stays, kept where it is or in the
        \\trash, with its pieces as `plugin data` lists them, and its own trash entry while
        \\it is there. `plugin erase_data` purges pieces; `trash restore` brings them back.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        plugins: []const Left,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .plugins = &example_left,
    };
    pub const field_docs: operation.Docs(In) = .{};
};
