//! A term's status moves: transitions, publishing, discarding changes, deleting, purging.
const operation = @import("../../operation.zig");
const term = @import("../term.zig");

const example_id = term.example_id;
const example_changed_id = term.example_changed_id;
const example_draft_id = term.example_draft_id;

pub const Transition = struct {
    pub const name = "term.transition";
    pub const description = "Move a term by a transition of its flow: publish, archive, ...";
    pub const details =
        \\As `record transition`: the transition by name, into a live status applies pending
        \\edits, out of one keeps them. Bumps `version`.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        transition: []const u8,
        expected_version: ?i64 = null,
    };
    pub const Out = struct {
        status: []const u8,
        changed: bool,
        version: i64,
    };
    pub const example: In = .{
        .id = example_draft_id,
        .transition = "publish",
    };
    pub const example_out: Out = .{
        .status = "published",
        .changed = false,
        .version = 2,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The term id",
        .transition = "The transition's name, `publish`",
        .expected_version = "The `version` you read; refuse if it changed",
    };
};

pub const Publish = struct {
    pub const name = "term.publish";
    pub const description = "Make the term's latest document live";
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        expected_version: ?i64 = null,
    };
    pub const Out = Transition.Out;
    pub const example: In = .{
        .id = example_changed_id,
    };
    pub const example_out: Out = .{
        .status = "published",
        .changed = false,
        .version = 2,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The term id",
        .expected_version = "The `version` you read; refuse if it changed",
    };
};

pub const DiscardChanges = struct {
    pub const name = "term.discard_changes";
    pub const description = "Drop a term's pending edits; the document stays as it is";
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        expected_version: ?i64 = null,
    };
    pub const Out = struct {
        version: i64,
    };
    pub const example: In = .{
        .id = example_changed_id,
    };
    pub const example_out: Out = .{
        .version = 4,
    };
};

pub const Delete = struct {
    pub const name = "term.delete";
    pub const description = "Move a term to `deleted` (reversible: transition back to draft)";
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        expected_version: ?i64 = null,
    };
    pub const Out = Transition.Out;
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .status = "trashed",
        .changed = false,
        .version = 2,
    };
};

pub const Purge = struct {
    pub const name = "term.purge";
    pub const description = "Remove a term for good; refused while it has children or records";
    pub const details =
        \\Admins only. A term with child terms, or one that records are filed under
        \\(directly or through a descendant), answers `conflict`: move the children and
        \\the records first.
    ;
    pub const kind: operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        purged: bool,
    };
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .purged = true,
    };
};
