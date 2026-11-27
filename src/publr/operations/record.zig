//! Records: the content itself, one document of one content type in one status. Reading,
//! writing and listing them here; moving them between statuses, scheduling, versions and
//! the editor's reads in the sub-files.
const std = @import("std");
const operation = @import("../operation.zig");
const model = @import("../model/record.zig");
const extended = @import("../extended.zig");

const Extended = extended.Extended;
const Dimensions = @import("../dimension_input.zig").Dimensions;

pub const Record = model.Record;
pub const Purpose = model.Purpose;
pub const Order = model.Order;
pub const Problem = model.Problem;
pub const Referrer = model.Referrer;
pub const Transition = lifecycle.Transition;
pub const TransitionAt = lifecycle.TransitionAt;
pub const Unschedule = lifecycle.Unschedule;
pub const RunScheduled = lifecycle.RunScheduled;
pub const Reschedule = lifecycle.Reschedule;
pub const Publish = lifecycle.Publish;
pub const DiscardChanges = lifecycle.DiscardChanges;
pub const Delete = lifecycle.Delete;
pub const Purge = lifecycle.Purge;
pub const SaveVersion = versions.SaveVersion;
pub const PublishVersion = versions.PublishVersion;
pub const SaveIntoScheduled = versions.SaveIntoScheduled;
pub const TransitionMany = @import("record/many.zig").TransitionMany;
pub const CreateMany = @import("record/create_many.zig").CreateMany;
pub const DeclineRequest = @import("record/requests.zig").DeclineRequest;
pub const HoldBack = @import("record/hold_back.zig").HoldBack;
pub const Shown = @import("record/shown.zig").Shown;
pub const Title = @import("record/shown.zig").Title;
pub const Markers = @import("record/markers.zig").Markers;
pub const Marker = @import("record/markers.zig").Marker;
pub const Helps = @import("record/help.zig").Helps;
pub const Help = @import("record/help.zig").Help;
pub const Query = @import("record/query.zig").Query;
pub const Reach = @import("record/reach.zig").Reach;
const lifecycle = @import("record/lifecycle.zig");
const versions = @import("record/versions.zig");

pub const namespace: operation.Namespace = .{
    .name = "record",
    .label = "Records",
    .area = .content,
    .summary = "The content itself: one document per record, in one status",
    .details =
    \\A record is one document of one content type in one status. Documents are JSON
    \\objects shaped by the type's fields and validated on every write. Each write bumps
    \\the record's `version`; pass `expected_version` to refuse overwriting someone
    \\else's change.
    \\
    \\Status is the publication axis (`draft`, `published`, `archived`, `deleted`,
    \\moved by `record transition`); `changed` is the editing axis: saving a live record
    \\parks the edit in a pending copy and sets `changed`, the live document stays as
    \\it is until `record publish` applies the copy, or `record discard_changes` drops
    \\it. Unpublishing, archiving and deleting keep pending edits as they are.
    \\
    \\Anyone may read live records of public types; signed-in users read and write
    \\everything their role allows.
    ,
};

pub const example_id = "a1b2c3d4e5f60718293a4b5c";
pub const example_changed_id = "b2c3d4e5f60718293a4b5c6d";
pub const example_draft_id = "c3d4e5f60718293a4b5c6d7e";
/// A live record with a change scheduled on it (entry 1): what the scheduling examples name.
pub const example_scheduled_id = "d4e5f60718293a4b5c6d7e8f";
pub const example_document = "{\"title\":\"Hello, world\",\"body\":\"<p>First post.</p>\"}";
pub const example_record: Record = .{
    .id = example_id,
    .type_id = "7c2d9e4f1a8b3c5d6e7f8a9b",
    .type = "post",
    .status = "published",
    .changed = false,
    .version = 3,
    .title = "Hello, world",
    .slug = "hello-world",
    .created_by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .updated_by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .created_at = 1789650000000,
    .updated_at = 1789653600000,
};

pub const Create = struct {
    pub const name = "record.create";
    pub const description = "Create a record of a type from a JSON document";
    pub const details =
        \\The document is validated against the type's fields; the title comes from
        \\the type's `title_field`. When the type has a `slug` field it is filled from
        \\its source (or the title) when the document leaves it empty, and made unique
        \\per type. It starts in its flow's first status (`draft`); a status changes only by
        \\a transition (`record transition`). A record lives where its type does; only the
        \\design's records (templates, parts, patterns, moodboard cards), which each app has
        \\its own of, take `app`: the one named, else the app the request came through.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        document: operation.Json,
        app: ?[]const u8 = null,
    };
    pub const Out = model.Created;
    pub const example: In = .{
        .type = "post",
        .document = .{
            .text = example_document,
        },
    };
    pub const example_out: Out = .{
        .id = example_id,
        .status = "draft",
        .slug = "hello-world",
        .version = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "The content type, by handle or id",
        .document = "The document as a JSON object",
        .app = "A design record's app, by `.name`; refused for any other type",
    };
};

pub const Get = struct {
    pub const name = "record.get";
    pub const description = "Read one record with its document";
    pub const details =
        \\A signed-in caller reads the latest copy: the pending changes when the record has
        \\some, else its live document; a page drawn for a visitor, and an anonymous caller,
        \\the live document. `purpose` says how virtual fields come back: `delivery`
        \\(default) worked out, as a site or API consumer wants them; `edit` as the admin
        \\editor keeps them, to save back. `slot` names a copy explicitly (`live`,
        \\`pending`, or a plugin's own). Anonymous callers only see live records of public
        \\types; anything else answers not found.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
        purpose: Purpose = .delivery,
        slot: ?[]const u8 = null,
        dimensions: Dimensions = .{},
        /// A scheduled version to read the record as (an entry of `scheduled`): what is live
        /// with every version up to it laid over. Signed-in callers only.
        version: i64 = 0,
        /// The type the record is of: another type's record is not found. A plugin's code
        /// naming its own type reads it whoever the request is for.
        type: ?[]const u8 = null,
    };
    pub const Out = model.Got;
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .record = example_record,
        .slot = "live",
        .document = .{
            .text = example_document,
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .purpose = "`delivery` or `edit`",
        .slot = "Read this copy instead (`live`, `pending`, ...); signed-in callers only",
        .dimensions = "Read each field in a combination: `--language pl` (and a flag per " ++
            "other dimension the site has), falling back to the code without its region, " ++
            "then the main value; an empty code asks for the main value",
        .type = "The type the record must be of; another type's is not found",
    };
};

pub const Save = struct {
    pub const name = "record.save";
    pub const description = "Write a record's fields: straight in for drafts, parked when live";
    pub const details =
        \\Writes the fields the document gives over the copy it changes; a field left out
        \\keeps its value. Validates the whole, keeps the slug unless the document sets one,
        \\bumps `version`. Pass the `version` you last read as `expected_version` and the
        \\save is refused (`conflict`) if someone saved in between. On a live record (or one
        \\that already has pending edits) the fields are parked in the pending copy and the
        \\record is marked `changed`; the live document is untouched until `record publish`.
        \\Otherwise they go into the record's own document, the old one kept as a revision
        \\snapshot. A save never changes the status: that is `record transition`.
        \\`outcome` says what it did: `saved` (into the record's own document),
        \\`changes_saved` (parked), `changes_discarded` (an edit taken back to the live
        \\document), `unchanged`.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        document: operation.Json,
        expected_version: ?i64 = null,
        /// The type the record is of: another type's is not found. A plugin's code naming
        /// its own type writes it whoever the request is for.
        type: ?[]const u8 = null,
    };
    pub const Out = model.Saved;
    pub const example: In = .{
        .id = example_id,
        .document = .{
            .text = example_document,
        },
    };
    pub const example_out: Out = .{
        .version = 3,
        .slug = "hello-world",
        .changed = true,
        .outcome = "changes_saved",
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .document = "The fields to write, as a JSON object; the others keep their values",
        .expected_version = "The `version` you read; refuse if it changed",
        .type = "The type the record must be of; another type's is not found",
    };
};

pub const List = struct {
    pub const name = "record.list";
    pub const description = "List records, of one type or across the content, with status, " ++
        "author, time, filter, search, order and paging";
    pub const details =
        \\With no `type` (nor `types`) the list spans regular content types the caller may read.
        \\Settings require an explicit `type` or `types` selection.
        \\`filters` are clauses, `key:operator:value` each, of the filters the registry
        \\knows (the core ones, and a plugin's): `status:is:draft`, `status:not:archived`,
        \\`changed:is:pending` (or `none`), `created:by:me` (a user id or `me`; `updated`
        \\the same), `updated:within:7d` (`24h`, `7d`, `30d`, `90d`),
        \\`created:after:2026-01-01`, `created:before:2026-02-01`. An
        \\empty value asks nothing. Within one type, filter on any field by its path
        \\(`filter_field` + `filter_value`; `seo.title`, `faq.question` for nested ones;
        \\numbers and booleans compare as numbers, `true` = 1; references and images by
        \\the target id); search uses fields marked `searchable` (full text). A signed-in
        \\caller's filters, search, order and documents read each record's latest copy (its
        \\pending changes, else its live document); a page drawn for a visitor, and an
        \\anonymous caller, read live ones. Anonymous callers get live records of public
        \\types only.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        type: ?[]const u8 = null,
        types: []const []const u8 = &.{},
        filters: []const []const u8 = &.{},
        search: ?[]const u8 = null,
        slug: ?[]const u8 = null,
        filter_field: ?[]const u8 = null,
        filter_value: ?[]const u8 = null,
        filter_values: []const []const u8 = &.{},
        ids: []const []const u8 = &.{},
        exclude_statuses: []const []const u8 = &.{},
        order: Order = .updated_desc,
        sort: ?[]const u8 = null,
        limit: u32 = 50,
        offset: u32 = 0,
        /// Also count every record the list's conditions keep, past this page.
        count: bool = false,
        documents: bool = false,
        /// With `documents`: virtual fields worked out (`false` reads what they keep).
        expand: bool = true,
        /// With `documents`: `edit` gives the pending copy of a record with changes.
        purpose: Purpose = .delivery,
        dimensions: Dimensions = .{},
    };
    pub const Out = struct {
        records: []const Record,
        /// With `documents`: each record's live document, in the records' order.
        documents: []const operation.Json = &.{},
        /// With `count`: how many records the conditions keep, every page together.
        total: u32 = 0,
        extended: Extended = .{},

        /// A field of the hooking plugin's own on a record: `out.extend(record,
        /// "loyalty.points", 120)`.
        pub fn extend(
            out: *const Out,
            record: Record,
            field: []const u8,
            value: anytype,
        ) extended.Error!void {
            std.debug.assert(record.id.len > 0);

            return out.extended.put(record.id, field, value);
        }
    };
    pub const example: In = .{
        .type = "post",
        .filters = &.{"status:is:published"},
        .limit = 20,
    };
    pub const example_out: Out = .{
        .records = &.{example_record},
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "One content type, by handle or id",
        .types = "Several content types, by handle or id; " ++
            "neither: every readable regular content type",
        .filters = "Clauses, `key:operator:value` each: `status:is:draft`, " ++
            "`updated:within:7d`; on a field of one type, `field.total:more:4999`, " ++
            "`field.placed:in_the_past:7d`, `field.size:any_of:[\"s\",\"m\"]`",
        .search = "Full-text query over searchable fields",
        .slug = "Only the record whose slug field holds this value (a type with a slug field)",
        .filter_field = "A field path (`views`, `seo.title`, `tags`); one type only",
        .filter_value = "The value to match (text, number, true/false, or an id for references)",
        .filter_values = "With `filter_field`: any of these values (references or text)",
        .ids = "Only these records, by id (up to the page size)",
        .exclude_statuses = "Never records in these statuses, whatever `filters` ask",
        .order = "`updated_desc` (default), `updated_asc`, `created_desc`, `created_asc`, " ++
            "`title_asc`, `title_desc`, `status_asc` or `status_desc`",
        .sort = "Order by a field of one type instead of `order`: `total`, `-total` descending",
        .limit = "Page size, up to 200",
        .offset = "Rows to skip",
        .count = "Also return `total`: every record the conditions keep, past this page " ++
            "(before per-record checks a plugin's grant adds)",
        .documents = "Also return each record's live document, read with the page in one go",
        .expand = "With documents: virtual fields as the records they stand for (default)",
        .purpose = "With documents: `edit` reads pending copies where there are changes",
        .dimensions = "Titles, slugs and documents in a combination: `--language pl` (and a " ++
            "flag per other dimension); `slug` then matches that language's slug first",
    };
};

pub const Referrers = struct {
    pub const name = "record.referrers";
    pub const description = "List the records whose references point at a record or media item";
    pub const details =
        \\Every reference and image value is a pointer to another record, and Publr keeps
        \\a reverse index of them. Give a record id (or a media id) and get back who
        \\points at it and through which field. Only records the caller may read are
        \\listed. A page at a time, in the order of the records: `next` continues it; a
        \\page may hold fewer than 200 when some are left out.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
        after: []const u8 = "",
    };
    pub const Out = struct {
        referrers: []const Referrer,
        next: []const u8 = "",
    };
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .referrers = &.{
            .{
                .record_id = "9b1e7c3d5a2f4e6b8d0c1a3f",
                .field = "related",
            },
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The target record or media id",
        .after = "The page after this one: the `next` the last page answered",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .referrers = "Record id and field path (`related`, `faq.link`) that points at the target",
        .next = "The next page's `after`; empty after the last",
    };
};

pub const Validate = struct {
    pub const name = "record.validate";
    pub const description = "Check a document against a type and list every problem without saving";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        type: []const u8,
        document: operation.Json,
    };
    pub const Out = model.Report;
    pub const example: In = .{
        .type = "post",
        .document = .{
            .text = "{\"body\":\"no title\",\"extra\":1}",
        },
    };
    pub const example_out: Out = .{
        .valid = false,
        .problems = &.{
            .{
                .path = "title",
                .message = "required",
            },
            .{
                .path = "extra",
                .message = "unknown field",
            },
        },
    };
};
