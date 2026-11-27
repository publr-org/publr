//! Frozen copies of a record's document, numbered per record: the revisions core takes when a
//! live document is replaced, and the kinds plugins take of their own (`order.completed`).
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "snapshot",
    .label = "Versions",
    .area = .content,
    .summary = "Frozen copies of a record's document: revisions and other archives",
    .details =
    \\A snapshot is a read-only, point-in-time copy of a record's document, numbered per
    \\record. The core takes one of kind `revision` whenever a live document is replaced;
    \\plugins take their own kinds (`order.completed`, ...). Snapshots are never edited;
    \\restoring one is a normal `record save` of its document. Signed-in callers only.
    ,
};

pub const Item = struct {
    seq: i64,
    kind: []const u8,
    at: i64,
    by: ?[]const u8,
    /// The document's title; empty where it has none.
    title: []const u8 = "",
    /// The document; in a list, only when asked for.
    document: ?operation.Json = null,
};

const example_id = "a1b2c3d4e5f60718293a4b5c";
const example_item: Item = .{
    .seq = 1,
    .kind = "revision",
    .at = 1789650000000,
    .by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .document = .{
        .text = "{\"title\":\"Hello, world\",\"body\":\"<p>First post.</p>\"}",
    },
};

pub const List = struct {
    pub const name = "snapshot.list";
    pub const description = "List a record's snapshots, newest first, a page at a time";
    pub const details =
        \\Each with its title; its document only with `documents`. `before` reads the page
        \\older than a snapshot: a page's `next_before`.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
        kind: ?[]const u8 = null,
        before: i64 = 0,
        limit: u32 = 50,
        documents: bool = false,
    };
    pub const Out = struct {
        snapshots: []const Item,
        /// Where the next page starts; 0 after the oldest.
        next_before: i64 = 0,
    };
    pub const example: In = .{
        .id = example_id,
        .kind = "revision",
    };
    pub const example_out: Out = .{
        .snapshots = &.{example_item},
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .kind = "Only this kind (`revision`, ...); every kind when omitted",
        .before = "Only the ones older than this sequence number: a page's `next_before`",
        .limit = "How many, 50 when omitted, up to 200",
        .documents = "Each snapshot's document too",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .snapshots = "Newest first: seq, kind, at, by, title, and the document when asked",
        .next_before = "The next page's `before`; 0 after the oldest",
    };
};

pub const Get = struct {
    pub const name = "snapshot.get";
    pub const description = "Read one snapshot of a record";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
        seq: i64,
    };
    pub const Out = Item;
    pub const example: In = .{
        .id = example_id,
        .seq = 1,
    };
    pub const example_out: Out = example_item;
};

pub const Take = struct {
    pub const name = "snapshot.take";
    pub const description = "Freeze a record's live document under a kind of your own";
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        kind: []const u8,
    };
    pub const Out = struct {
        seq: i64,
    };
    pub const example: In = .{
        .id = example_id,
        .kind = "order.completed",
    };
    pub const example_out: Out = .{
        .seq = 1,
    };
};

pub const Restore = struct {
    pub const name = "snapshot.restore";
    pub const description = "Write a snapshot's document back through `record save`";
    pub const details =
        \\A normal save: on a live record the restored document lands as pending changes
        \\(publish to make it live), on a draft it replaces the document; either way the
        \\version it replaces is kept as a new revision snapshot.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        seq: i64,
        expected_version: ?i64 = null,
    };
    pub const Out = struct {
        version: i64,
        changed: bool,
    };
    pub const example: In = .{
        .id = example_id,
        .seq = 1,
    };
    pub const example_out: Out = .{
        .version = 3,
        .changed = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .seq = "The snapshot to restore",
        .expected_version = "The record `version` you read; refuse if it changed",
    };
};

pub const Prune = struct {
    pub const name = "snapshot.prune";
    pub const description = "Keep only the newest snapshots of a kind for a record";
    pub const kind: operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        id: []const u8,
        kind: []const u8,
        keep: u32,
    };
    pub const Out = struct {
        removed: u32,
    };
    pub const example: In = .{
        .id = example_id,
        .kind = "revision",
        .keep = 20,
    };
    pub const example_out: Out = .{
        .removed = 0,
    };
};
