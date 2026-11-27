//! A live record's scheduled changes, each on a base: what is live (no base) or another
//! scheduled change it builds on. One reads as the record will be at its moment: what is live
//! with its chain of bases and itself laid over, in order. Changes on the same base never
//! share a field: changing it again is a change on top of the one that has it. Edits made on
//! top of one are a draft on it until they are scheduled (`record.transition_at` with that
//! base), saved into it (`record.save_into_scheduled`) or dropped (`record.unschedule`).
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

pub const SaveVersion = struct {
    pub const name = "record.save_version";
    pub const description = "Keep edits made on top of a scheduled change, as a draft";
    pub const details =
        \\Takes the whole document as it should read (`record get --version`) and keeps what
        \\differs from the scheduled change as a draft on it: nothing is scheduled until
        \\`record transition_at` with it as `base` schedules the draft on top of it, or
        \\`record save_into_scheduled` puts it into the change itself. Back to what the
        \\change reads, the draft goes. Live is untouched.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        version: i64,
        document: operation.Json,
    };
    pub const Out = struct {
        /// Whether a draft is kept on it.
        changed: bool,
    };
    pub const example: In = .{
        .id = record.example_scheduled_id,
        .version = 1,
        .document = .{
            .text = "{\"title\":\"Back to normal\"}",
        },
    };
    pub const example_out: Out = .{
        .changed = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .version = "The scheduled change, from `scheduled` in `record get`",
        .document = "The whole document as it should read",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .changed = "Whether edits are kept on it, waiting to be scheduled or saved into it",
    };
};

pub const SaveIntoScheduled = struct {
    pub const name = "record.save_into_scheduled";
    pub const description = "Put the edits made on top of a scheduled change into it";
    pub const details =
        \\The draft on the change (`record save_version`) becomes part of it: the change
        \\then sets those fields too, at its moment. Refused when another change on the same
        \\base already changes one of them.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        version: i64,
    };
    pub const Out = struct {
        saved: bool,
    };
    pub const example: In = .{
        .id = record.example_scheduled_id,
        .version = 1,
    };
    pub const example_out: Out = .{
        .saved = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .version = "The scheduled change, from `scheduled` in `record get`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .saved = "Always true; not found when nothing waits on it",
    };
};

pub const PublishVersion = struct {
    pub const name = "record.publish_version";
    pub const description = "Put a scheduled change live now, with what it builds on";
    pub const details =
        \\The record goes live as the change reads, now, as you: the changes it builds on
        \\go live with it and leave the schedule; changes beside it and on top of it keep
        \\their moments, now on what is live. Checked as a publish is.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        version: i64,
    };
    pub const Out = @import("lifecycle.zig").Transition.Out;
    pub const example: In = .{
        .id = record.example_scheduled_id,
        .version = 1,
    };
    pub const example_out: Out = .{
        .status = "published",
        .changed = false,
        .version = 3,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .version = "The scheduled change, from `scheduled` in `record get`",
    };
};
