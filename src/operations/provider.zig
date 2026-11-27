//! The providers of each contract (`publr.contract.define`), compiled in or installed: which
//! are on, and in what order the owner tries them. The administrator manages both; the
//! provider's own settings are on its plugin's page.
const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const model = @import("../model.zig");
const contract = @import("../sdk/contract.zig");
const operation_define = @import("../publr/plugin/operation_define.zig");
const public = @import("../publr/operations/provider.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const operations = [_]type{ List, Set } ++ @import("provider/answers.zig").operations;

pub const Listed = public.Listed;
pub const Shown = public.Shown;

fn shown_of(ctx: *Ctx, provider: contract.Registered) Error!Shown {
    std.debug.assert(provider.name.len > 0);

    const labels = @import("plugin/labels.zig");
    const label = if (provider.label.len > 0) provider.label else provider.name;
    const plugin = if (provider.plugin.len > 0)
        model.plugin_label.of(provider.plugin, labels.summary_of(ctx, provider.plugin))
    else
        "";

    return .{
        .label = try said(ctx, label),
        .plugin = if (plugin.len > 0 and plugin.ptr != provider.plugin.ptr)
            try said(ctx, plugin)
        else
            plugin,
    };
}

fn said(ctx: *Ctx, text: []const u8) Error![]const u8 {
    std.debug.assert(text.len > 0);

    return ctx.say(ctx.speaks(), .{
        .id = text,
        .plural = "",
        .count = null,
        .values = &.{},
    }) catch error.OutOfMemory;
}

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const untrusted_callers = shape.untrusted_callers;
    pub const answer = shape.answer;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.contract.len == 0 or in.contract.len > contract.name_len_max) {
            return error.Invalid;
        }

        if (in.can.len > contract.parts_max) {
            return error.Invalid;
        }

        var found: std.ArrayList(contract.Registered) = .empty;
        var on: std.ArrayList(bool) = .empty;
        var shown: std.ArrayList(Shown) = .empty;

        for (try contract.listed(ctx, in.contract)) |one| {
            if ((one.on or !in.on_only) and one.provider.has_all(in.can)) {
                try found.append(ctx.arena, one.provider);
                try on.append(ctx.arena, one.on);
                try shown.append(ctx.arena, try shown_of(ctx, one.provider));
            }
        }

        return .{
            .providers = found.items,
            .on = on.items,
            .shown = shown.items,
        };
    }
};

pub const Set = struct {
    pub const shape = public.Set;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.contract.len == 0 or in.contract.len > contract.name_len_max) {
            return error.Invalid;
        }

        if (in.order.len > contract.providers_max or in.off.len > contract.providers_max) {
            return error.Invalid;
        }

        // An installed plugin sets only the contracts it owns; compiled-in code is as built.
        if (ctx.caller == .plugin) {
            if (ctx.caller.plugin.access) |access| {
                if (!owns(access.contracts, in.contract)) {
                    return error.Denied;
                }
            }
        }

        const choice: contract.Choice = .{
            .order = in.order,
            .off = in.off,
        };
        const text = try sdk.stringify(ctx.arena, choice);
        const key = try contract.setting_key(ctx.arena, in.contract);

        try store.settings.set(ctx.db, key, text, ctx.now_ms);

        return .{
            .contract = in.contract,
        };
    }
};

fn owns(owned: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (owned) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}
