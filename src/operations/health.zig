//! Site Health: what is quietly wrong in the project, listed so it never spreads unseen, each
//! case decided on its own. Its first section is broken references: records pointing at a
//! record in the trash, gone for good, or of a type no longer shared with their app.

const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const cases_module = @import("health/cases.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Reason = cases_module.Reason;
pub const Holder = cases_module.Holder;
pub const Case = cases_module.Case;

pub const namespace: sdk.operation.Namespace = .{
    .name = "health",
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
pub const operations = [_]type{
    List,
    Count,
    Keep,
    Unlink,
    translations.Translations,
    translations.ChooseTranslation,
    translations.MissingTranslations,
};

const page_default: u32 = 50;
const page_max: u32 = 200;

/// A page of cases from a walk of all of them: the ones after `after`, up to `limit`, with
/// titles; the kept ones counted over all.
const Paging = struct {
    in: List.In,
    shown: std.ArrayList(Case) = .empty,
    kept: u32 = 0,
    next: []const u8 = "",
    /// The target of the last case shown: a target's cases stay on one page.
    last: []const u8 = "",

    fn visit(paging: *Paging, ctx: *Ctx, case: Case) Error!bool {
        std.debug.assert(case.target.len > 0);

        paging.kept += @intFromBool(case.kept);

        const listed = !case.kept or paging.in.kept;
        const past = paging.in.after.len == 0 or
            std.mem.order(u8, case.target, paging.in.after) == .gt;

        if (!listed or !past or paging.next.len > 0) {
            return true;
        }

        const full = paging.shown.items.len >= paging.in.limit;

        if (full and !std.mem.eql(u8, case.target, paging.last)) {
            paging.next = paging.last;
            return true;
        }

        const shown = try cases_module.titled(ctx, case);

        try paging.shown.append(ctx.arena, shown);
        paging.last = shown.target;

        return true;
    }
};

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
    pub const kind: sdk.operation.Kind = .read;
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
        .cases = &.{cases_module.example},
        .kept = 0,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .kept = "Also the cases kept as they are",
        .after = "The cases after this record pointed at: a page's `next`",
        .limit = "How many cases at most; 50 when omitted, up to 200",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .cases = "Each record pointed at: `target`, `type`, `title`, `reason`, `app` (the " ++
            "app that lost the type, for `not_shared`), `holders` (the first ten), " ++
            "`holders_total` and whether it is `kept`",
        .kept = "How many cases are kept as they are",
        .next = "Where the next page starts; empty after the last",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.limit == 0 or in.limit > page_max) {
            return error.Invalid;
        }

        var paging: Paging = .{
            .in = in,
        };

        try cases_module.walk(ctx, .count, .{
            .after = "",
        }, &paging, Paging.visit);

        return .{
            .cases = paging.shown.items,
            .kept = paging.kept,
            .next = paging.next,
        };
    }
};

pub const Count = struct {
    pub const name = "health.count";
    pub const description = "Count the broken references not kept as they are";
    pub const details =
        \\What the Settings sidebar shows beside Site Health: the cases `health list`
        \\answers, without them.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        count: u32,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .count = 0,
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .count = "Cases not kept as they are",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const Counting = struct {
            count: u32 = 0,

            fn visit(counting: *@This(), _: *Ctx, case: Case) Error!bool {
                counting.count += @intFromBool(!case.kept);

                return true;
            }
        };
        var counting: Counting = .{};

        try cases_module.walk(ctx, .count, .{
            .after = "",
        }, &counting, Counting.visit);

        const disagreeing = try translations.listed(ctx);

        return .{
            .count = counting.count + disagreeing.open,
        };
    }
};

pub const Keep = struct {
    pub const name = "health.keep";
    pub const description = "Leave a broken reference as it is";
    pub const details =
        \\The card stays in the editor and the restricted payload on the site; the case
        \\leaves the list until its reason or the number of records pointing changes.
        \\Not found when there is no such case.
    ;
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .target = "The record pointed at, by id",
        .app = "For `not_shared`, the app whose records point at it",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .kept = "Always true",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const case = try cases_module.find(ctx, in.target, in.app) orelse return error.NotFound;

        store.health_kept.put(ctx.db, .{
            .target = case.target,
            .app = case.app,
            .reason = @tagName(case.reason),
            .holders = case.holders_total,
        }, ctx.now_ms) catch return error.Failed;

        return .{
            .kept = true,
        };
    }
};

pub const Unlink = struct {
    pub const name = "health.unlink";
    pub const description = "Take a broken reference out of the records that hold it";
    pub const details =
        \\Every record of the case loses its pointer at the target, in its live document
        \\and its pending changes; nothing else of them changes. Not found when there is
        \\no such case.
    ;
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .target = "The record pointed at, by id",
        .app = "For `not_shared`, the app whose records point at it",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .removed = "How many pointers were taken out",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const case = try cases_module.find(ctx, in.target, in.app) orelse return error.NotFound;
        const Unlinking = struct {
            target: []const u8,
            removed: u32 = 0,

            fn visit(unlinking: *@This(), inner: *Ctx, holder: []const u8) Error!void {
                std.debug.assert(holder.len > 0);

                unlinking.removed += store.values.delete_reference(
                    inner.db,
                    holder,
                    unlinking.target,
                ) catch return error.Failed;
            }
        };
        var unlinking: Unlinking = .{
            .target = case.target,
        };

        try cases_module.each_holder(ctx, case.target, case.app, &unlinking, Unlinking.visit);

        return .{
            .removed = unlinking.removed,
        };
    }
};

test {
    _ = cases_module;
    _ = model;
}

const registry = @import("../server/registry.zig");
const record_operations = @import("record.zig");
const SDK = registry.SDK;

test "site health: a type no longer shared and a deleted target are cases; keep and unlink" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    const types = @import("content_type.zig");
    const title: model.field.Def = .{
        .name = "title",
        .label = "Title",
        .kind = "string",
        .required = true,
    };
    var stock: model.content_type.Def = .{
        .handle = "stock",
        .name = "Stock",
        .public = true,
        .app = "shop",
        .shared = .{
            .apps = &.{"www"},
        },
        .fields = &.{title},
    };
    const product: model.content_type.Def = .{
        .handle = "product",
        .name = "Product",
        .public = true,
        .app = "www",
        .fields = &.{ title, .{
            .name = "stock",
            .label = "Stock",
            .kind = "reference",
            .many = true,
        } },
    };

    for ([_]model.content_type.Def{ stock, product }) |def| {
        _ = try SDK.dispatch(&system, types.Create, .{
            .definition = try model.content_type.encode(system.arena, def),
        });
    }

    const mug = (try SDK.dispatch(&system, record_operations.Create, .{
        .type = "stock",
        .document = "{\"title\":\"Blue mug\"}",
        .status = "published",
    })).id;
    const cup = (try SDK.dispatch(&system, record_operations.Create, .{
        .type = "stock",
        .document = "{\"title\":\"Cup\"}",
        .status = "published",
    })).id;
    const document = try std.fmt.allocPrint(
        system.arena,
        "{{\"title\":\"Mug\",\"stock\":[\"{s}\",\"{s}\"]}}",
        .{ mug, cup },
    );
    _ = try SDK.dispatch(&system, record_operations.Create, .{
        .type = "product",
        .document = document,
        .status = "published",
    });

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_ad",
            .roles = &.{"admin"},
        },
    });
    try std.testing.expectEqual(0, (try SDK.dispatch(&admin, Count, .{})).count);

    stock.shared = null;
    _ = try SDK.dispatch(&system, types.Update, .{
        .type = "stock",
        .definition = try model.content_type.encode(system.arena, stock),
    });
    _ = try SDK.dispatch(&system, record_operations.Delete, .{
        .id = cup,
    });

    const listed = try SDK.dispatch(&admin, List, .{});
    try std.testing.expectEqual(2, listed.cases.len);

    for (listed.cases) |case| {
        const deleted = std.mem.eql(u8, case.target, cup);
        const reason: Reason = if (deleted) .deleted else .not_shared;
        try std.testing.expectEqual(reason, case.reason);
        try std.testing.expectEqualStrings(if (deleted) "" else "www", case.app);
        try std.testing.expectEqualStrings("Mug", case.holders[0].title);
    }

    _ = try SDK.dispatch(&admin, Keep, .{
        .target = mug,
        .app = "www",
    });
    const after_keep = try SDK.dispatch(&admin, List, .{});
    try std.testing.expectEqual(1, after_keep.cases.len);
    try std.testing.expectEqual(1, after_keep.kept);
    try std.testing.expectEqual(1, (try SDK.dispatch(&admin, Count, .{})).count);

    const unlinked = try SDK.dispatch(&admin, Unlink, .{
        .target = cup,
    });
    try std.testing.expectEqual(1, unlinked.removed);
    try std.testing.expectEqual(0, (try SDK.dispatch(&admin, Count, .{})).count);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&admin, Unlink, .{
        .target = cup,
    }));

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, List, .{}));
}

test "site health: cases come a page at a time, a case's records counted across chunks" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    const types = @import("content_type.zig");
    const title: model.field.Def = .{
        .name = "title",
        .label = "Title",
        .kind = "string",
        .required = true,
    };
    const stock: model.content_type.Def = .{
        .handle = "stock",
        .name = "Stock",
        .public = true,
        .fields = &.{title},
    };
    const product: model.content_type.Def = .{
        .handle = "product",
        .name = "Product",
        .public = true,
        .fields = &.{ title, .{
            .name = "stock",
            .label = "Stock",
            .kind = "reference",
        } },
    };

    for ([_]model.content_type.Def{ stock, product }) |def| {
        _ = try SDK.dispatch(&system, types.Create, .{
            .definition = try model.content_type.encode(system.arena, def),
        });
    }

    // Four stock items in the trash: the first pointed at by six products, the rest by one.
    var targets: [4][]const u8 = undefined;

    for (&targets, 0..) |*target, index| {
        target.* = (try SDK.dispatch(&system, record_operations.Create, .{
            .type = "stock",
            .document = "{\"title\":\"Item\"}",
            .status = "published",
        })).id;

        const holders: u32 = if (index == 0) 6 else 1;
        var made: u32 = 0;

        while (made < holders) : (made += 1) {
            _ = try SDK.dispatch(&system, record_operations.Create, .{
                .type = "product",
                .document = try std.fmt.allocPrint(
                    system.arena,
                    "{{\"title\":\"Product\",\"stock\":\"{s}\"}}",
                    .{target.*},
                ),
                .status = "published",
            });
        }
    }

    for (targets) |target| {
        _ = try SDK.dispatch(&system, record_operations.Delete, .{
            .id = target,
        });
    }

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_ad",
            .roles = &.{"admin"},
        },
    });
    try std.testing.expectEqual(4, (try SDK.dispatch(&admin, Count, .{})).count);

    var seen: u32 = 0;
    var after: []const u8 = "";
    var pages: u32 = 0;

    while (pages < 4) : (pages += 1) {
        const page = try SDK.dispatch(&admin, List, .{
            .after = after,
            .limit = 2,
        });

        try std.testing.expect(page.cases.len <= 2);

        for (page.cases) |case| {
            const many = std.mem.eql(u8, case.target, targets[0]);
            try std.testing.expectEqual(@as(u32, if (many) 6 else 1), case.holders_total);
            try std.testing.expectEqual(Reason.deleted, case.reason);
            seen += 1;
        }

        if (page.next.len == 0) {
            break;
        }

        after = page.next;
    }

    try std.testing.expectEqual(4, seen);
    try std.testing.expectEqual(1, pages);

    const unlinked = try SDK.dispatch(&admin, Unlink, .{
        .target = targets[0],
    });
    try std.testing.expectEqual(6, unlinked.removed);
    try std.testing.expectEqual(3, (try SDK.dispatch(&admin, Count, .{})).count);
}
