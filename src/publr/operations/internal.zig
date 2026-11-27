//! Internal records: what a plugin keeps for itself (carts, reservations, ledgers), one JSON
//! document each, in collections the plugin declares. Called from a plugin's own code, every
//! operation reaches that plugin's records in the app the request came through, and nobody
//! else's. With no plugin running, an administrator names the plugin (and the app).
const operation = @import("../operation.zig");
const event_define = @import("../plugin/hook_define.zig").event;
const writes = @import("internal/writes.zig");
const reads = @import("internal/reads.zig");
const computed = @import("internal/computed.zig");

pub const namespace: operation.Namespace = .{
    .name = "internal",
    .label = "Plugin records",
    .area = .background,
    .summary = "A plugin's internal records: what it keeps for itself, never content",
    .details =
    \\Carts, reservations, stock movements, logs: records a plugin keeps and nobody edits,
    \\in collections it declares (`internal_records`), each with the fields it is found
    \\by. No statuses, drafts, revisions or search; `version` guards a stale write. From a
    \\plugin's code they reach that plugin's records in the request's app only. With no
    \\plugin running, an administrator names `plugin` (and `app`, the project's own when
    \\left out). An append-only collection refuses `save` and `delete`. Every write runs the
    \\collection's field rules as content's: bounds and shapes, a unique value (another
    \\record holding it is a conflict), a provider field naming an installed provider.
    ,
};

pub const example_id = "c3d4e5f60718293a4b5c6d7e";
pub const example_document = "{\"name\":\"Ada\",\"count\":1}";

/// An internal record as the operations answer it.
pub const Item = struct {
    id: []const u8,
    version: i64,
    document: operation.Json,
    created_at: i64,
    updated_at: i64,
};

pub const example_item: Item = .{
    .id = example_id,
    .version = 1,
    .document = .{
        .text = example_document,
    },
    .created_at = 1767225600000,
    .updated_at = 1767225600000,
};

pub const Create = writes.Create;
pub const CreateMany = writes.CreateMany;
pub const Save = writes.Save;
pub const SaveMany = writes.SaveMany;
pub const Delete = writes.Delete;
pub const Get = reads.Get;
pub const FindOne = reads.FindOne;
pub const Find = reads.Find;
pub const Count = reads.Count;
pub const Sum = computed.Sum;
pub const HoldsUntil = computed.HoldsUntil;

/// What core's internal-record events carry.
pub const Changed = struct {
    /// The internal record: `<plugin>/<kind>/<id>`
    record: []const u8,
};

/// An internal record was made.
pub const Created = event_define(.{
    .name = "internal.created",
    .payload = Changed,
});
/// An internal record was saved.
pub const Saved = event_define(.{
    .name = "internal.saved",
    .payload = Changed,
});
/// An internal record was deleted.
pub const Deleted = event_define(.{
    .name = "internal.deleted",
    .payload = Changed,
});
