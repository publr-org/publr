//! The piece a provider draws on its owner's admin pages: a record whose provider field (a
//! `publr.ProviderRef`) names it shows the provider's `.panel` beside it, drawn in the
//! provider's frame as any panel (a pickup point picker on the order that chose the
//! lockers). Neither side names the other: the owner's type has the field, the provider
//! registers the panel into the contract.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const contract = @import("../../../sdk/contract.zig");
const content_type = @import("../../../operations/content_type.zig");
const Panel = @import("panels.zig").Panel;

const Session = admin.Session;

/// Every provider panel a record of `handle` may show, for the viewer: one per provider of
/// each contract a provider field of the type names, marked with the field and the provider
/// a record must hold to show it.
pub fn of_type(
    session: *const Session,
    handle: []const u8,
    into: *std.ArrayList(Panel),
    panels_max: u32,
) admin.Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(handle.len > 0);

    var reading = session.*;
    const got = registry.SDK.dispatch(&reading.ctx, content_type.Get, .{
        .type = handle,
    }) catch return;

    for (got.definition.fields) |field| {
        const contract_name = field.options.provider.contract;

        if (!std.mem.eql(u8, field.kind, "provider") or contract_name.len == 0) {
            continue;
        }

        const listed = contract.listed(&reading.ctx, contract_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };

        for (listed) |one| {
            const provider = one.provider;

            if (provider.panel.len == 0 or into.items.len == panels_max) {
                continue;
            }

            if (!registry.SDK.may_named(&reading.ctx, provider.panel)) {
                continue;
            }

            try into.append(session.arena, .{
                .plugin = provider.plugin,
                .type = handle,
                .label = if (provider.label.len > 0)
                    try session.declared(provider.label)
                else
                    provider.name,
                .operation = provider.panel,
                .chosen_by = field.name,
                .provider = provider.name,
            });
        }
    }
}

/// Whether `panel` shows on the record `document` holds: any panel of its type, a
/// provider's only when the record chose that provider.
pub fn shows(panel: Panel, document: ?std.json.Value) bool {
    std.debug.assert(panel.operation.len > 0);

    if (panel.chosen_by.len == 0) {
        return true;
    }

    std.debug.assert(panel.provider.len > 0);

    const data = document orelse return false;

    if (data != .object) {
        return false;
    }

    const held = data.object.get(panel.chosen_by) orelse return false;

    return held == .string and std.mem.eql(u8, held.string, panel.provider);
}

test "a provider's panel shows on the record that chose it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const panel: Panel = .{
        .plugin = "lockers",
        .type = "order",
        .label = "Lockers",
        .operation = "lockers.picker",
        .chosen_by = "delivery",
        .provider = "lockers",
    };
    const chose = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{ "delivery": "lockers" }
    , .{});
    const other = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{ "delivery": "courier" }
    , .{});
    var any = panel;

    any.chosen_by = "";

    try std.testing.expect(shows(panel, chose));
    try std.testing.expect(!shows(panel, other));
    try std.testing.expect(!shows(panel, null));
    try std.testing.expect(shows(any, null));
}
