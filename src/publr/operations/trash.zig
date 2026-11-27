//! The trash: what a removal took, kept as it was (a copy of its rows) until it is emptied,
//! restorable meanwhile, and the records in the trash, which stay where they are. A removal
//! keeps its copy here before it runs (`keep`); the trash empties what it has held for
//! `trash.keep_days` (30 unless set): copies go, records are destroyed by their `destroy`
//! transition, hooks and all. Only emptying, or removing one entry for good, is final, and
//! only a person or Publr itself does it.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "trash",
    .label = "Trash",
    .area = .content,
    .summary = "The trash: what was removed, restorable until it is emptied",
    .details =
    \\Removing a content type, a taxonomy or a field group keeps a copy of everything it
    \\takes (its records, terms, values, snapshots) here before it goes. `trash restore`
    \\brings it back as it was. Records in the trash are listed too, by their own id:
    \\`trash restore` runs their `restore` transition, `trash remove` their `destroy`. The
    \\trash empties what it has held for `trash.keep_days` days (30 unless set); `trash
    \\remove` and `trash empty` remove for good sooner. Those two are final, so a device (an
    \\agent) lists them for its person instead.
    ,
};

pub const keep_days_default: u32 = 30;

pub const Shown = struct {
    id: []const u8,
    /// `content_type`, `taxonomy`, `field_group`, …
    kind: []const u8,
    key: []const u8,
    label: []const u8,
    removed_by: []const u8,
    conversation_id: []const u8,
    removed_at: i64,
    /// When it goes for good.
    keep_until: i64,
};

pub const example_shown: Shown = .{
    .id = "0190a1b2c3d40001a1b2c3d4",
    .kind = "content_type",
    .key = "recipe",
    .label = "Content type Recipe, and its 12 records",
    .removed_by = "0190a1b2c3d40001a1b2c3d5",
    .conversation_id = "",
    .removed_at = 1789650000000,
    .keep_until = 1792242000000,
};

pub const List = struct {
    pub const name = "trash.list";
    pub const description = "List what the trash holds, newest first";
    pub const details =
        \\Every removed thing still restorable, with who removed it, when, and when it goes for
        \\good. A conversation's only, with `conversation`.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        conversation: []const u8 = "",
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        entries: []const Shown,
        keep_days: u32,
        total: u32 = 0,
        /// The records in the trash, the same page of them: `kind` is `record`, `key` the
        /// type, `id` the record's own.
        records: []const Shown = &.{},
        records_total: u32 = 0,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .entries = &.{example_shown},
        .keep_days = keep_days_default,
        .total = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .conversation = "Only what this conversation's agent removed",
        .limit = "How many at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first: the next page's start",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .entries = "What it holds, newest first",
        .keep_days = "How many days it keeps something before removing it for good",
        .total = "How many entries it holds in all (the conversation's, when named)",
        .records = "Records in the trash, the longest there first; none for a conversation",
        .records_total = "How many records are in the trash",
    };
};

pub const Restore = struct {
    pub const name = "trash.restore";
    pub const description = "Bring something back from the trash, as it was";
    pub const details =
        \\Everything the removal took comes back: a content type with its records, their
        \\values, terms and snapshots. Refused when something new took its name meanwhile.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        kind: []const u8,
        key: []const u8,
        label: []const u8,
    };
    pub const example: In = .{
        .id = example_shown.id,
    };
    pub const example_out: Out = .{
        .kind = "content_type",
        .key = "recipe",
        .label = example_shown.label,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The trash entry's id",
    };
};

pub const Remove = struct {
    pub const name = "trash.remove";
    pub const description = "Remove one thing in the trash for good";
    pub const details =
        \\Its copy goes, and it can never be restored; a record in the trash is destroyed by
        \\its `destroy` transition. Final, so a device lists it for its person instead.
    ;
    pub const kind: operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        removed: bool,
    };
    pub const example: In = .{
        .id = example_shown.id,
    };
    pub const example_out: Out = .{
        .removed = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The trash entry's id",
    };
};

pub const Empty = struct {
    pub const name = "trash.empty";
    pub const description = "Empty the trash: what it holds goes for good";
    pub const details =
        \\Everything, or only what it has held past `trash.keep_days` with `expired`: copies
        \\go, records in the trash are destroyed by their `destroy` transition. Final, so a
        \\device lists it for its person instead. Publr itself empties what is past its time.
    ;
    pub const kind: operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        expired: bool = false,
    };
    pub const Out = struct {
        removed: u32,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .removed = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .expired = "Only what it has held longer than it keeps things",
    };
};

pub const Keep = struct {
    pub const name = "trash.keep";
    pub const description = "Set how long the trash keeps things before removing them for good";
    pub const details =
        \\`days` for everything in the trash and all that is removed from now on: each entry
        \\goes that many days after it was removed. 1 to 3650.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        days: u32,
    };
    pub const Out = struct {
        days: u32,
    };
    pub const example: In = .{
        .days = 30,
    };
    pub const example_out: Out = .{
        .days = 30,
    };
    pub const field_docs: operation.Docs(In) = .{
        .days = "How many days, 1 to 3650",
    };
};
