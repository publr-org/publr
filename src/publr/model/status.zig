//! The statuses a record can be in and the transitions between them, as `status.list`
//! answers them: core's own and what plugins add.

pub const id_len_max: u32 = 32;
pub const statuses_max: u32 = 64;
pub const transitions_max: u32 = 200;

pub const Color = enum { neutral, info, success, warning, danger };

pub const Status = struct {
    id: []const u8,
    label: []const u8,
    color: Color = .neutral,
    live: bool = false,
    listed: bool = true,
    initial: bool = false,
    /// Another plugin's status this one stands in for (`orders.paid`): with that one known,
    /// it takes its label, colour and visibility, and a filter asking for it finds this one.
    alias: []const u8 = "",
};

pub const Transition = struct {
    from: []const u8,
    to: []const u8,
    label: []const u8,
};

pub const core_statuses = [_]Status{
    .{
        .id = "draft",
        .label = "Draft",
        .initial = true,
    },
    .{
        .id = "published",
        .label = "Published",
        .color = .success,
        .live = true,
    },
    .{
        .id = "archived",
        .label = "Archived",
        .listed = false,
    },
    .{
        .id = "trashed",
        .label = "In the trash",
        .color = .danger,
        .listed = false,
    },
};

pub const core_transitions = [_]Transition{
    .{
        .from = "draft",
        .to = "published",
        .label = "Publish",
    },
    .{
        .from = "published",
        .to = "draft",
        .label = "Unpublish",
    },
    .{
        .from = "draft",
        .to = "archived",
        .label = "Archive",
    },
    .{
        .from = "published",
        .to = "archived",
        .label = "Archive",
    },
    .{
        .from = "archived",
        .to = "draft",
        .label = "Restore",
    },
    .{
        .from = "draft",
        .to = "trashed",
        .label = "Delete",
    },
    .{
        .from = "published",
        .to = "trashed",
        .label = "Delete",
    },
    .{
        .from = "archived",
        .to = "trashed",
        .label = "Delete",
    },
    .{
        .from = "trashed",
        .to = "draft",
        .label = "Restore",
    },
    .{
        .from = "trashed",
        .to = "archived",
        .label = "Restore",
    },
};
