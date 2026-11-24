//! Site Health's translations tab, its other half: how much of each domain's messages each
//! language translates, and by whom.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const translations = @import("translations.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

/// One language over one domain's messages.
pub const Covered = struct {
    locale: []const u8,
    label: []const u8,
    /// `publr` for the core's words, a plugin's name for its own.
    domain: []const u8,
    translated: u32,
    total: u32,
    /// The plugins bringing this language's translations of the domain.
    providers: []const []const u8,
};

pub const Coverage = struct {
    pub const name = "health.coverage";
    pub const description = "How much of each domain's messages each language translates";
    pub const details =
        \\Administrators only. Each language over each domain's messages (`publr` for the
        \\core's words, a plugin's name for its own): how many it translates, of how many, and
        \\the plugins bringing them. A page of 200 at a time: `next` continues it.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        after: []const u8 = "",
    };
    pub const Out = struct {
        coverage: []const Covered,
        next: []const u8 = "",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .coverage = &.{},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .after = "The page after this one: the `next` the last page answered",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .coverage = "Each language over each domain's messages: how many it translates, by whom",
        .next = "The next page's `after`; empty after the last",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const start = try translations.position_of(in.after);
        const view = ctx.translations orelse return .{
            .coverage = &.{},
        };
        const all = view.coverage(view.context);
        const first = @min(start, all.len);
        const end = @min(all.len, first + sdk.operation.page_limit_max);
        const out = ctx.arena.alloc(Covered, end - first) catch return error.OutOfMemory;

        for (all[first..end], out) |coverage, *covered| {
            covered.* = .{
                .locale = coverage.locale,
                .label = coverage.label,
                .domain = coverage.domain,
                .translated = coverage.translated,
                .total = coverage.total,
                .providers = coverage.providers,
            };
        }

        return .{
            .coverage = out,
            .next = if (end < all.len)
                std.fmt.allocPrint(ctx.arena, "{d}", .{end}) catch return error.OutOfMemory
            else
                "",
        };
    }
};
