//! Site Health: what is quietly wrong in the project, listed so it never spreads unseen, each
//! case decided on its own. Its first section is broken references: records pointing at a
//! record in the trash, gone for good, or of a type no longer shared with their app.
const operation = @import("../operation.zig");

pub const Translations = translations.Translations;
pub const MissingTranslations = translations.MissingTranslations;
pub const ChooseTranslation = translations.ChooseTranslation;
pub const Candidate = translations.Candidate;
pub const Disagreement = translations.Disagreement;
pub const Coverage = coverage.Coverage;
pub const Covered = coverage.Covered;

pub const namespace: operation.Namespace = .{
    .name = "health",
    .label = "Site health",
    .area = .site,
    .summary = "Site Health: what is quietly wrong in the project, to decide case by case",
    .details =
    \\Broken references first: records that point at a record in the trash (`deleted`),
    \\one gone for good (`gone`), or one whose type is no longer shared with their app
    \\(`not_shared`). Each case is worked out from the references themselves; `health
    \\keep` leaves one as it is until something about it changes, `health unlink` takes
    \\the pointers out of the records that hold them. Restoring the record (`record
    \\transition --to draft`) or sharing its type again also settle a case. Administrators
    \\only.
    ,
};

pub const translations = @import("health/translations.zig");
pub const coverage = @import("health/coverage.zig");

pub const Reason = enum { deleted, gone, not_shared };

/// The records pointing at a case it names, the first of them; `holders_total` counts all.
pub const holders_shown_max: u32 = 10;

pub const Holder = struct {
    id: []const u8,
    type: []const u8,
    title: []const u8,
};

pub const Case = struct {
    target: []const u8,
    /// Its type's handle; empty when it is gone for good.
    type: []const u8,
    title: []const u8,
    reason: Reason,
    /// For `not_shared`, the app whose records point at it; empty otherwise.
    app: []const u8,
    /// The first records pointing at it, up to `holders_shown_max`.
    holders: []const Holder,
    /// How many records point at it.
    holders_total: u32,
    kept: bool,
};

pub const page_default: u32 = 50;

pub const List = struct {
    pub const name = "health.list";
    pub const description = "List the broken references, one case per record pointed at";
    pub const details =
        \\One case per record pointed at (and, for a type no longer shared, per app whose
        \\records point at it): what it is, why it is broken, the records that still point
        \\at it (the first ten, and how many in all). Cases kept as they are are left out
        \\unless `kept` asks for them; `kept` in the answer counts them either way. A page
        \\at a time, in the order of the record pointed at: `next` continues it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        kept: bool = false,
        after: []const u8 = "",
        limit: u32 = page_default,
    };
    pub const Out = struct {
        cases: []const Case,
        kept: u32,
        next: []const u8 = "",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .cases = &.{},
        .kept = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .kept = "Also the cases kept as they are",
        .after = "The cases after this record pointed at: a page's `next`",
        .limit = "How many cases at most; 50 when omitted, up to 200",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .cases = "Each record pointed at: `target`, `type`, `title`, `reason`, `app` (the " ++
            "app that lost the type, for `not_shared`), `holders` (the first ten), " ++
            "`holders_total` and whether it is `kept`",
        .kept = "How many cases are kept as they are",
        .next = "Where the next page starts; empty after the last",
    };
};

pub const Count = struct {
    pub const name = "health.count";
    pub const description = "Count the broken references not kept as they are";
    pub const details =
        \\What the Settings sidebar shows beside Site Health: the cases `health list`
        \\answers, without them.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        count: u32,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .count = 0,
    };
    pub const output_docs: operation.Docs(Out) = .{
        .count = "Cases not kept as they are",
    };
};

pub const Keep = struct {
    pub const name = "health.keep";
    pub const description = "Leave a broken reference as it is";
    pub const details =
        \\The card stays in the editor and the restricted payload on the site; the case
        \\leaves the list until its reason or the number of records pointing changes.
        \\Not found when there is no such case.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        target: []const u8,
        app: []const u8 = "",
    };
    pub const Out = struct {
        kept: bool,
    };
    pub const example: In = .{
        .target = "a1b2c3d4e5f60718293a4b5c",
    };
    pub const example_out: Out = .{
        .kept = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .target = "The record pointed at, by id",
        .app = "For `not_shared`, the app whose records point at it",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .kept = "Always true",
    };
};

pub const Unlink = struct {
    pub const name = "health.unlink";
    pub const description = "Take a broken reference out of the records that hold it";
    pub const details =
        \\Every record of the case loses its pointer at the target, in its live document
        \\and its pending changes; nothing else of them changes. Not found when there is
        \\no such case.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        target: []const u8,
        app: []const u8 = "",
    };
    pub const Out = struct {
        removed: u32,
    };
    pub const example: In = .{
        .target = "a1b2c3d4e5f60718293a4b5c",
    };
    pub const example_out: Out = .{
        .removed = 3,
    };
    pub const field_docs: operation.Docs(In) = .{
        .target = "The record pointed at, by id",
        .app = "For `not_shared`, the app whose records point at it",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .removed = "How many pointers were taken out",
    };
};
