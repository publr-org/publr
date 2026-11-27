//! Records as the record operations answer them: one row with what every reader wants next to
//! it, and what creating, reading, saving and checking one answers.
const operation = @import("../operation.zig");
const document = @import("document.zig");

pub const Problem = document.Problem;
pub const Record = document.Record;
pub const Order = document.Order;
pub const Purpose = document.Purpose;
pub const Report = document.Report;

pub const Created = struct {
    id: []const u8,
    status: []const u8,
    slug: ?[]const u8,
    version: i64,
};
pub const Got = struct {
    record: Record,
    slot: []const u8,
    document: operation.Json,
    /// What is scheduled for it (`record.transition_at`), soonest first; read for the editor.
    scheduled: []const Scheduled = &.{},
};
pub const Scheduled = struct {
    /// Its id, for `record.unschedule`.
    entry: i64,
    transition: []const u8,
    at: i64,
    /// The person it is made as.
    by: []const u8,
    /// A scheduled publish of changes rather than a plain transition.
    version: bool = false,
    /// The scheduled change it builds on; 0 for what is live.
    base: i64 = 0,
    /// A scheduled publish's changes: the keys it publishes (`title@language=pl`).
    changes: []const []const u8 = &.{},
    /// What it holds back once made, when that changes; null leaves it.
    held_back: ?[]const u8 = null,
    /// `waiting`, or `failed` with `problem` saying why.
    state: []const u8 = "waiting",
    problem: []const u8 = "",
};

pub const Saved = struct {
    version: i64,
    slug: ?[]const u8,
    changed: bool,
    /// What the save did: `saved` (the live document written), `changes_saved` (kept as
    /// pending changes), `changes_discarded` (an edit taken back), `unchanged`.
    outcome: []const u8,
};
pub const Referrer = struct {
    record_id: []const u8,
    field: []const u8,
};

/// A record a write over many left as it was, and why.
pub const Failed = struct {
    id: []const u8,
    title: []const u8,
    why: []const u8,
};
