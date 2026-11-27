//! Removal lists: what an agent asked to remove for good, waiting for its person. An agent
//! never removes: running a removal as a device puts it on the device's list instead, and
//! the person reviews the list, keeps what should stay and removes the rest, as themselves.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "removal",
    .label = "Removal lists",
    .area = .content,
    .summary = "Removal lists: what an agent asked to remove, for a person to confirm",
    .details =
    \\A device (an agent) never removes anything for good. When it runs a removal (purging a
    \\record, deleting a content type, removing a plugin), nothing is removed: the removal goes
    \\on the device's list, in words, for its person. The person reads the list, keeps what
    \\should stay, and removes the rest (`removal confirm`), as themselves, under their own
    \\permissions. Some things are never removed from a list (your own account): the list
    \\says how to do them by hand.
    ,
};

pub const Summary = struct {
    id: []const u8,
    state: []const u8,
    conversation_id: []const u8,
    /// Items still waiting for the person.
    waiting: u32,
    items: u32,
    created_at: i64,
};

pub const Item = struct {
    position: u32,
    operation: []const u8,
    label: []const u8,
    detail: []const u8,
    /// Why it never goes from a list, and how to remove it by hand; empty when it may.
    blocked: []const u8,
    /// `waiting`, `removed`, `trashed`, `kept`, `failed` or `blocked`.
    state: []const u8,
    message: []const u8,
};

pub const example_summary: Summary = .{
    .id = "0190a1b2c3d40001a1b2c3d4",
    .state = "waiting",
    .conversation_id = "",
    .waiting = 2,
    .items = 2,
    .created_at = 1789650000000,
};

pub const List = struct {
    pub const name = "removal.list";
    pub const description = "List the caller's removal lists, newest first";
    pub const details =
        \\Only the waiting ones unless `all`. A person's own lists; a device's person's.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        all: bool = false,
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        lists: []const Summary,
        total: u32 = 0,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .lists = &.{example_summary},
    };
    pub const field_docs: operation.Docs(In) = .{
        .all = "Done lists too",
        .limit = "How many at most; 50 when omitted, up to 50",
        .offset = "How many to pass over first: the next page's start",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .lists = "A page of the lists, newest first",
        .total = "How many there are in all",
    };
};

pub const Get = struct {
    pub const name = "removal.get";
    pub const description = "Read a removal list: every item, in words, and where it stands";
    pub const details =
        \\The caller's own lists only.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        list: Summary,
        items: []const Item,
    };
    pub const example: In = .{
        .id = example_summary.id,
    };
    pub const example_out: Out = .{
        .list = example_summary,
        .items = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The list's id",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .list = "The list",
        .items = "Its items in order",
    };
};

pub const Confirm = struct {
    pub const name = "removal.confirm";
    pub const description = "Remove what a removal list holds, but what you keep";
    pub const details =
        \\Every waiting item runs as the caller, each through its own operation and its own
        \\permissions, except the positions in `keep`, which stay. Each item that fails says
        \\why; the rest go on. Then the list is done. A person only, never a device.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
        keep: []const u32 = &.{},
        trash: bool = false,
    };
    pub const Out = Get.Out;
    pub const example: In = .{
        .id = example_summary.id,
        .keep = &.{2},
    };
    pub const example_out: Out = Get.example_out;
    pub const field_docs: operation.Docs(In) = .{
        .id = "The list's id",
        .keep = "The positions to keep; every other waiting item is removed",
        .trash = "Move records and terms to the trash instead (restorable); the rest go for good",
    };
};

pub const Decline = struct {
    pub const name = "removal.decline";
    pub const description = "Keep everything a removal list holds";
    pub const details =
        \\Nothing is removed; the list is done. A person only, never a device.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = Get.Out;
    pub const example: In = .{
        .id = example_summary.id,
    };
    pub const example_out: Out = Get.example_out;
    pub const field_docs: operation.Docs(In) = .{
        .id = "The list's id",
    };
};
