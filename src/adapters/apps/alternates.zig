//! A page in the site's other languages: its address in each, for the `hreflang` links the
//! core writes into its head and for a language switch a template draws
//! (`Publr.build.languages()`). A `[slug]` page's address in a language uses the record's
//! slug there, or its main one where it has none. Absolute, so a root path written into a
//! page under one language's address never takes that address.
const std = @import("std");
const engine = @import("../../template.zig");
const registry = @import("../../server/registry.zig");
const variants = @import("../../operations/variants.zig");
const record_operations = @import("../../operations/record.zig");
const model_variant = @import("../../model/variant.zig");
const context_module = @import("context.zig");

const Context = context_module.Context;

pub const Alternate = struct {
    /// `pl`; the main language's own code too.
    code: []const u8,
    label: []const u8,
    href: []const u8,
    /// The language the page is in.
    current: bool,
    main: bool,
};

/// The page's address in every language, the main one first; empty on a site without
/// languages, or for a page drawn without a route (a fragment, the 404).
pub fn of(ctx: *const Context) ![]const Alternate {
    std.debug.assert(ctx.app.url.len > 0);
    std.debug.assert(ctx.place.address.len == 0 or ctx.place.address[0] == '/');

    const route = ctx.route orelse return &.{};
    var sdk_ctx = ctx.sdk_context();
    const listed = try variants.listed(&sdk_ctx);
    const id = if (route.kind == .dynamic) try record_id(ctx, route) else null;

    if (route.kind == .dynamic and id == null) {
        return &.{};
    }

    var out: std.ArrayList(Alternate) = .empty;

    for (listed) |variant| {
        const stored = if (variant.main) "" else variant.code;
        const path = if (id) |record|
            try path_in(ctx, route, record, stored) orelse continue
        else
            route.pattern;
        const address = if (variant.main) "" else variant.address;
        const under = try model_variant.under(ctx.arena, address, path);

        try out.append(ctx.arena, .{
            .code = variant.code,
            .label = variant.label,
            .href = try std.mem.concat(ctx.arena, u8, &.{ ctx.app.url, under }),
            .current = std.mem.eql(u8, stored, ctx.place.variant),
            .main = variant.main,
        });
    }

    return out.items;
}

/// The record a `[slug]` page shows, by its slug in the page's language.
fn record_id(ctx: *const Context, route: *const engine.Route) !?[]const u8 {
    std.debug.assert(route.kind == .dynamic);

    const slug = ctx.params.slug orelse return null;
    const template = &ctx.app.pages().templates[route.template];
    const type_id = @import("build.zig").entry_type_of(template) orelse return null;
    var sdk_ctx = ctx.sdk_context();
    const listed = registry.SDK.dispatch(&sdk_ctx, record_operations.List, .{
        .type = type_id,
        .slug = slug,
        .limit = 1,
    }) catch return null;

    return if (listed.records.len == 0) null else listed.records[0].id;
}

/// The page's path in the app for `record` read in `variant`: its slug there.
fn path_in(
    ctx: *const Context,
    route: *const engine.Route,
    record: []const u8,
    variant: []const u8,
) !?[]const u8 {
    std.debug.assert(record.len > 0);
    std.debug.assert(route.kind == .dynamic);

    var sdk_ctx = ctx.sdk_context();
    const got = registry.SDK.dispatch(&sdk_ctx, record_operations.Get, .{
        .id = record,
        .variant = variant,
    }) catch return null;
    const slug = got.record.slug orelse return null;

    return try engine.substitute(ctx.arena, route.pattern, slug);
}

/// `<link rel="alternate" hreflang>` for every language, and `x-default` for the main one.
pub fn write_links(ctx: *const Context, writer: *std.Io.Writer) !void {
    std.debug.assert(ctx.app.url.len > 0);

    const all = of(ctx) catch return;

    if (all.len < 2) {
        return;
    }

    for (all) |alternate| {
        try writer.print("<link rel=\"alternate\" hreflang=\"{s}\" href=\"{s}\">", .{
            alternate.code,
            alternate.href,
        });

        if (alternate.main) {
            try writer.print("<link rel=\"alternate\" hreflang=\"x-default\" href=\"{s}\">", .{
                alternate.href,
            });
        }
    }
}
