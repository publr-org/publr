//! The terms of the taxonomies: what records are classified under. A term is one document
//! of one taxonomy in one status, with a record's lifecycle; in a hierarchical taxonomy a
//! term may have a parent term.
const operation = @import("../operation.zig");
const document = @import("../model/document.zig");
const Dimensions = @import("../dimension_input.zig").Dimensions;

pub const namespace: operation.Namespace = .{
    .name = "term",
    .label = "Terms",
    .area = .content,
    .summary = "The terms of the taxonomies: what records are classified under",
    .details =
    \\A term is one document of one taxonomy in one status, with the same lifecycle as a
    \\record: a validated JSON document shaped by the taxonomy's fields, a `version`,
    \\statuses moved by `term transition`, pending edits parked by `term save` on a live
    \\term and applied by `term publish`, revisions in `snapshot list`. In a hierarchical
    \\taxonomy a term may have a `parent` term of the same taxonomy, up to 16 levels;
    \\a record assigned to a term is a member of every ancestor as well.
    \\
    \\Anyone may read live terms of public taxonomies; signed-in users read and write
    \\everything their role allows.
    ,
};

pub const Purpose = document.Purpose;
pub const Order = document.Order;
pub const Problem = document.Problem;
/// A term as reads answer it: the record shape every document has.
pub const Term = document.Record;

const lifecycle = @import("term/lifecycle.zig");
pub const Transition = lifecycle.Transition;
pub const Publish = lifecycle.Publish;
pub const DiscardChanges = lifecycle.DiscardChanges;
pub const Delete = lifecycle.Delete;
pub const Purge = lifecycle.Purge;

pub const example_id = "e5f60718293a4b5c6d7e8f90";
pub const example_parent_id = "f60718293a4b5c6d7e8f9012";
pub const example_changed_id = "0718293a4b5c6d7e8f901234";
pub const example_draft_id = "18293a4b5c6d7e8f90123456";
pub const example_document = "{\"name\":\"Engineering\"}";

/// An edit to the example term, which its save keeps as a change to publish.
pub const example_edit = "{\"name\":\"Engineering & Design\"}";

const example_term: Term = .{
    .id = example_id,
    .type_id = "d4e5f60718293a4b5c6d7e8f",
    .type = "topics",
    .status = "published",
    .changed = false,
    .version = 2,
    .title = "Engineering",
    .slug = "engineering",
    .created_by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .updated_by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .created_at = 1789650000000,
    .updated_at = 1789653600000,
};

pub const Node = struct {
    id: []const u8,
    parent: ?[]const u8,
    title: []const u8,
    slug: ?[]const u8,
    status: []const u8,
    depth: u32,
};

pub const Create = struct {
    pub const name = "term.create";
    pub const description = "Create a term of a taxonomy from a JSON document";
    pub const find_words = "add a category, add a tag, new topic";
    pub const details =
        \\The document is validated against the taxonomy's fields; the title comes from
        \\its `title_field`, the slug from the `slug` field's source when the document
        \\leaves it empty, unique per taxonomy. `parent` puts the term under another term
        \\of the same taxonomy, which must be hierarchical; at most 16 levels. It starts in
        \\its flow's first status (`draft`); a status changes only by a transition
        \\(`term transition`, `term publish`).
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        taxonomy: []const u8,
        document: operation.Json,
        parent: ?[]const u8 = null,
    };
    pub const Out = struct {
        id: []const u8,
        status: []const u8,
        slug: ?[]const u8,
        version: i64,
        parent: ?[]const u8,
    };
    pub const example: In = .{
        .taxonomy = "topics",
        .document = .{
            .text = example_document,
        },
    };
    pub const example_out: Out = .{
        .id = example_id,
        .status = "draft",
        .slug = "engineering",
        .version = 1,
        .parent = null,
    };
    pub const field_docs: operation.Docs(In) = .{
        .taxonomy = "The taxonomy, by handle or id",
        .document = "The document as a JSON object",
        .parent = "The parent term's id (hierarchical taxonomies)",
    };
};

pub const Get = struct {
    pub const name = "term.get";
    pub const description = "Read one term with its document and parent";
    pub const details =
        \\`purpose` says why: `delivery` (default) is the live document; `edit` is the
        \\pending copy when the term has unpublished changes, else the live document.
        \\`slot` names a copy explicitly. Anonymous callers only see live terms of public
        \\taxonomies; anything else answers not found.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
        purpose: Purpose = .delivery,
        slot: ?[]const u8 = null,
        dimensions: Dimensions = .{},
    };
    pub const Out = struct {
        term: Term,
        parent: ?[]const u8,
        slot: []const u8,
        document: operation.Json,
    };
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .term = example_term,
        .parent = example_parent_id,
        .slot = "live",
        .document = .{
            .text = example_document,
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The term id",
        .purpose = "`delivery` or `edit`",
        .slot = "Read this copy instead (`live`, `pending`, ...); signed-in callers only",
        .dimensions = "Read each field in a combination (`--language pl`), as `record get`",
    };
};

pub const Save = struct {
    pub const name = "term.save";
    pub const description = "Write a term's document, and move it in the hierarchy";
    pub const details =
        \\As `record save`: the fields given, straight in for drafts, parked as pending
        \\edits on a live term until `term publish`, never a change of status;
        \\`expected_version` refuses a stale write. `parent` moves the term under
        \\another term (an empty string makes it a root); left out, it stays where it is.
        \\Moving a term rewrites the assignments of every record filed under it or a
        \\descendant, so their ancestors follow; refused while more than 10 000
        \\assignments would change.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        document: operation.Json,
        expected_version: ?i64 = null,
        parent: ?[]const u8 = null,
    };
    pub const Out = struct {
        version: i64,
        slug: ?[]const u8,
        changed: bool,
        /// `saved`, `changes_saved`, `changes_discarded` or `unchanged`, as `record save`.
        outcome: []const u8,
        parent: ?[]const u8,
    };
    pub const example: In = .{
        .id = example_id,
        .document = .{
            .text = example_edit,
        },
    };
    pub const example_out: Out = .{
        .version = 3,
        .slug = "engineering",
        .changed = true,
        .outcome = "changes_saved",
        .parent = example_parent_id,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The term id",
        .document = "The fields to write, as a JSON object; the others keep their values",
        .expected_version = "The `version` you read; refuse if it changed",
        .parent = "The new parent term's id, or empty for none; omit to keep the parent",
    };
};

pub const List = struct {
    pub const name = "term.list";
    pub const description = "List terms, of one taxonomy or across all, with status, " ++
        "author, time, filter, search, order and paging";
    pub const details =
        \\As `record list`, over terms: with no `taxonomy` (nor `taxonomies`) the list
        \\spans every taxonomy the caller may read; `filters` take the registered
        \\clauses (`status:is:draft`, `updated:within:7d`); within one taxonomy filter on
        \\a field by path or pick the term with a `slug`. For the hierarchy, see
        \\`term tree`.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        taxonomy: ?[]const u8 = null,
        taxonomies: []const []const u8 = &.{},
        filters: []const []const u8 = &.{},
        search: ?[]const u8 = null,
        slug: ?[]const u8 = null,
        filter_field: ?[]const u8 = null,
        filter_value: ?[]const u8 = null,
        order: Order = .title_asc,
        limit: u32 = 50,
        offset: u32 = 0,
        dimensions: Dimensions = .{},
    };
    pub const Out = struct {
        terms: []const Term,
    };
    pub const example: In = .{
        .taxonomy = "topics",
        .filters = &.{"status:is:published"},
    };
    pub const example_out: Out = .{
        .terms = &.{example_term},
    };
    pub const field_docs: operation.Docs(In) = .{
        .taxonomy = "One taxonomy, by handle or id",
        .taxonomies = "Several taxonomies, by handle or id; neither: every readable one",
        .filters = "Clauses, `key:operator:value` each: `status:is:draft`, `updated:within:7d`",
        .search = "Full-text query over searchable fields",
        .slug = "Only the term whose slug field holds this value",
        .filter_field = "A field path; one taxonomy only",
        .filter_value = "The value to match",
        .order = "`title_asc` (default), `updated_desc` or `created_desc`",
        .limit = "Page size, up to 200",
        .offset = "Rows to skip",
        .dimensions = "Titles and slugs in a combination (`--language pl`)",
    };
};

pub const Tree = struct {
    pub const name = "term.tree";
    pub const description = "A taxonomy's terms in tree order, with their depth, a page at a time";
    pub const details =
        \\Parents come before their children, siblings by title, each term with its depth
        \\from 0. A flat taxonomy is a tree of roots. Anonymous callers get live terms of
        \\public taxonomies only; a hidden parent leaves its children at the root. A page of
        \\the tree at a time; `total` counts every term it places.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        taxonomy: []const u8,
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        terms: []const Node,
        total: u32 = 0,
    };
    pub const example: In = .{
        .taxonomy = "topics",
    };
    pub const example_out: Out = .{
        .terms = &.{
            .{
                .id = example_parent_id,
                .parent = null,
                .title = "Technology",
                .slug = "technology",
                .status = "published",
                .depth = 0,
            },
            .{
                .id = example_id,
                .parent = example_parent_id,
                .title = "Engineering",
                .slug = "engineering",
                .status = "published",
                .depth = 1,
            },
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .taxonomy = "The taxonomy, by handle or id",
        .limit = "How many terms at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first, in tree order: the next page's start",
    };
};

pub const Validate = struct {
    pub const name = "term.validate";
    pub const description = "Check a document against a taxonomy and list every problem";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        taxonomy: []const u8,
        document: operation.Json,
    };
    pub const Out = document.Report;
    pub const example: In = .{
        .taxonomy = "topics",
        .document = .{
            .text = "{\"slug\":\"no name\"}",
        },
    };
    pub const example_out: Out = .{
        .valid = false,
        .problems = &.{
            .{
                .path = "name",
                .message = "required",
            },
            .{
                .path = "slug",
                .message = "must be [a-z0-9] and hyphens",
            },
        },
    };
};
