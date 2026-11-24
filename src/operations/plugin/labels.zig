//! Plugins' names as people read them, in the caller's language: what a plugin shows where
//! another plugin did something (an order's timeline), and the admin beside what a plugin
//! draws.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

const names_max: u32 = 64;

pub const Named = struct {
    name: []const u8,
    label: []const u8,
};

pub const Labels = struct {
    pub const name = "plugin.labels";
    /// Changes nothing and tells only what every admin page shows: a plugin's code acting
    /// for anyone may ask.
    pub const open = true;
    pub const description = "Name plugins as people read them";
    pub const details =
        \\Each plugin named, compiled in or installed, as people read it: the words its
        \\summary opens with (`Bank transfer: ...` is "Bank transfer"), in the caller's
        \\language, else its name. A name no plugin has is answered as it was asked. Changes
        \\nothing; anyone may call it.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        names: []const []const u8,
    };
    pub const Out = struct {
        labels: []const Named,
    };
    pub const example: In = .{
        .names = &.{"bank_transfer"},
    };
    pub const example_out: Out = .{
        .labels = &.{.{
            .name = "bank_transfer",
            .label = "Bank transfer",
        }},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .names = "The plugins, by name; at most 64",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .labels = "Each name asked, with its label",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        if (in.names.len > names_max) {
            return error.Invalid;
        }

        const out = ctx.arena.alloc(Named, in.names.len) catch return error.OutOfMemory;

        for (in.names, out) |asked, *named| {
            const summary = summary_of(ctx, asked);
            const label = if (asked.len > 0) model.plugin_label.of(asked, summary) else asked;
            const shown = if (label.ptr == asked.ptr) label else try said(ctx, label);

            named.* = .{
                .name = asked,
                .label = shown,
            };
        }

        return .{
            .labels = out,
        };
    }
};

/// A plugin's summary, compiled in or installed; empty for a name no plugin has.
pub fn summary_of(ctx: *const Ctx, name: []const u8) []const u8 {
    std.debug.assert(name.len <= 1 << 10);

    inline for (registry.native_plugins.all) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, name)) {
            return Plugin.manifest.summary;
        }
    }

    const sandboxed = ctx.sandboxed_plugins orelse return "";

    for (sandboxed.manifests()) |manifest| {
        if (std.mem.eql(u8, manifest.name, name)) {
            return manifest.summary;
        }
    }

    return "";
}

fn said(ctx: *Ctx, label: []const u8) Error![]const u8 {
    std.debug.assert(label.len > 0);

    return ctx.say(ctx.speaks(), .{
        .id = label,
        .plural = "",
        .count = null,
        .values = &.{},
    }) catch error.OutOfMemory;
}
