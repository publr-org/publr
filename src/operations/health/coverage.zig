//! Site Health's translations tab, its other half: how much of each domain's messages each
//! language translates, and by whom.
const std = @import("std");
const public = @import("../../publr/operations/health/coverage.zig");
const sdk = @import("../../sdk.zig");
const translations = @import("translations.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

/// One language over one domain's messages.
pub const Covered = public.Covered;

pub const Coverage = struct {
    pub const shape = public.Coverage;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
