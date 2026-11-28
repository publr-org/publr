//! The record's status moves, declared; the bodies are the domain's `lifecycle`.
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

pub const Transition = struct {
    pub const name = "record.transition";
    pub const description = "Move a record by a transition of its type's flow: publish, " ++
        "archive, ...";
    pub const details =
        \\Names the transition, never the status: `publish`, `archive`, a type's own
        \\(`submit`), `trash` and `restore`. Refused unless the record is in one of the
        \\transition's `from` statuses and you pass the transition's own `authorize`.
        \\Moving into a live status applies pending edits first, like `record publish`;
        \\moving out of one keeps them parked. Bumps `version`; `expected_version` works as
        \\in save. Without the right to publish (`record publish`), a transition into or out
        \\of a live status, `destroy`, and `publish` of a live record's changes are asked
        \\for instead: `pending`, the record as it was, the request kept on it until someone
        \\who may runs it or `record decline_request` drops it.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        transition: []const u8,
        expected_version: ?i64 = null,
        /// The type the record is of: another type's is not found. A plugin's code naming
        /// its own type moves it whoever the request is for.
        type: ?[]const u8 = null,
    };
    pub const Out = struct {
        status: []const u8,
        changed: bool,
        version: i64,
        /// The transition waits for a person: the caller may only draft.
        pending: bool = false,
    };
    pub const example: In = .{
        .id = record.example_draft_id,
        .transition = "publish",
    };
    pub const example_out: Out = .{
        .status = "published",
        .changed = false,
        .version = 2,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .transition = "The transition's name, `publish`",
        .expected_version = "The `version` you read; refuse if it changed",
        .type = "The type the record must be of; another type's is not found",
    };
};

pub const TransitionAt = struct {
    pub const name = "record.transition_at";
    pub const description = "Schedule a transition of a record for a moment: publish on " ++
        "5 Nov at 9:00";
    pub const find_words = "schedule, later, publish at a time, timed, future, embargo";
    pub const details =
        \\A person schedules it; at that moment the server makes it as them, with the rights
        \\they hold then, as `record transition` would. A record may have any number
        \\scheduled, each its own entry (`scheduled` in `record get`) on a `base`: what is
        \\live, or another scheduled change it builds on (never earlier than it). `publish`
        \\on a live record schedules its changes: the pending ones on what is live, or the
        \\draft on `base` (`record save_version`); only the fields they change go live at
        \\its moment (`record publish` with `changes`). Changes on the same base never share
        \\a field: changing it again is a change on top of the one that has it. Nothing
        \\changed is refused. No `at` cancels every one of this transition. Never early;
        \\about a minute late at most. One refused then stays `failed`, with why.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        transition: []const u8,
        /// When, in ms; null cancels every one of this transition.
        at: ?i64 = null,
        /// The scheduled change it builds on (its draft is what `publish` schedules); 0 for
        /// what is live.
        base: i64 = 0,
    };
    pub const Out = struct {
        /// Whether one was scheduled.
        scheduled: bool,
        /// Its entry, for `record unschedule`; 0 when cancelled.
        entry: i64 = 0,
    };
    pub const example: In = .{
        .id = record.example_draft_id,
        .transition = "publish",
        .at = 1_792_405_800_000,
    };
    pub const example_out: Out = .{
        .scheduled = true,
        .entry = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .transition = "The transition's name, `publish`",
        .at = "When, in ms since 1970; leave it out to cancel every one of this transition",
        .base = "The scheduled change it builds on; leave it out for what is live",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .scheduled = "Whether one was scheduled",
        .entry = "The entry's id, for `record unschedule`",
    };
};

pub const Unschedule = struct {
    pub const name = "record.unschedule";
    pub const description = "Drop one thing scheduled for a record";
    pub const details =
        \\Takes the entry's id from `scheduled` in `record get`; a failed one is dropped the
        \\same way. The changes a scheduled publish kept go with it. Not found when the
        \\record has no such entry.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        entry: i64,
    };
    pub const Out = struct {
        removed: bool,
    };
    pub const example: In = .{
        .id = record.example_scheduled_id,
        .entry = 1,
    };
    pub const example_out: Out = .{
        .removed = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .entry = "The entry's id",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .removed = "Always true; not found otherwise",
    };
};

pub const RunScheduled = struct {
    pub const name = "record.run_scheduled";
    pub const description = "Make the next thing scheduled for a record now";
    pub const details =
        \\Only the record's next waiting entry (the first in `scheduled` from `record get`):
        \\one further on would run before what is scheduled ahead of it. Made now as you,
        \\with your rights, exactly as it would be at its time (`record publish` with its
        \\changes, or its transition), then dropped; the rest keep their times.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        entry: i64,
    };
    pub const Out = Transition.Out;
    pub const example: In = .{
        .id = record.example_scheduled_id,
        .entry = 1,
    };
    pub const example_out: Out = .{
        .status = "published",
        .changed = false,
        .version = 3,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .entry = "The next entry's id; any other is refused",
    };
};

pub const Reschedule = struct {
    pub const name = "record.reschedule";
    pub const description = "Move something scheduled for a record to another moment";
    pub const details =
        \\A waiting entry from `scheduled` in `record get`, to `at`; what it makes stays
        \\as it is. Not found for a failed one or one already made.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        entry: i64,
        at: i64,
    };
    pub const Out = struct {
        moved: bool,
    };
    pub const example: In = .{
        .id = record.example_scheduled_id,
        .entry = 1,
        .at = 1_792_405_800_000,
    };
    pub const example_out: Out = .{
        .moved = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .entry = "The entry's id",
        .at = "When, in ms since 1970",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .moved = "Always true; not found otherwise",
    };
};

pub const Publish = struct {
    pub const name = "record.publish";
    pub const description = "Make the record's latest document live";
    pub const details =
        \\From a draft: the document goes live (`draft -> published`). From a live
        \\record with pending edits: the pending copy becomes the live document, the
        \\old one is kept as a revision snapshot, `changed` clears. From a draft the move
        \\also raises the type's transition event. Refused when there is nothing to publish.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        expected_version: ?i64 = null,
        /// Only these fields, over what is live: a JSON object of each key and its value.
        changes: ?operation.Json = null,
        /// What it holds back with them; null leaves it as it is.
        held_back: ?[]const u8 = null,
    };
    pub const Out = Transition.Out;
    pub const example: In = .{
        .id = record.example_changed_id,
    };
    pub const example_out: Out = .{
        .status = "published",
        .changed = false,
        .version = 2,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .expected_version = "The `version` you read; refuse if it changed",
        .changes = "Publish only these fields onto what is live, a JSON object " ++
            "(`{\"title\":\"Deal\"}`, null empties one); pending edits stay parked",
        .held_back = "With `changes`: what it holds back once published, `;` between",
    };
};

pub const DiscardChanges = struct {
    pub const name = "record.discard_changes";
    pub const description = "Drop a record's pending edits; the document stays as it is";
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        expected_version: ?i64 = null,
    };
    pub const Out = struct {
        version: i64,
    };
    pub const example: In = .{
        .id = record.example_changed_id,
    };
    pub const example_out: Out = .{
        .version = 4,
    };
};

pub const Delete = struct {
    pub const name = "record.delete";
    pub const description = "Move a record to the trash (restorable: the `restore` transition)";
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        expected_version: ?i64 = null,
    };
    pub const Out = struct {
        status: []const u8,
        changed: bool,
        version: i64,
        /// The record's type: its list is where a person deleting it goes back to.
        type: []const u8,
    };
    pub const example: In = .{
        .id = record.example_id,
    };
    pub const example_out: Out = .{
        .status = "trashed",
        .changed = false,
        .version = 2,
        .type = "post",
    };
};

pub const Purge = struct {
    pub const name = "record.purge";
    pub const description = "Remove a record for good: document, pending edits and snapshots";
    pub const kind: operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        purged: bool,
    };
    pub const example: In = .{
        .id = record.example_id,
    };
    pub const example_out: Out = .{
        .purged = true,
    };
};
