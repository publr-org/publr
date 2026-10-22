//! Puts prices on the site.
//!
//! A plugin only ever installed, writing another type's records: notes the site keeps. It asks
//! for `records.write` on `note` with `.publish`, so an administrator can switch `.publish` off
//! and watch its new notes wait for approval, then switch it back on.
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;
const record = publr.operations.record;

const manifest: publr.Manifest = .{
    .name = "prices",
    .version = "0.1.0",
};

const operations = [_]type{Post};

pub const Post = struct {
    pub const name = "prices.post";
    pub const description = "Post a price as a note, and put it live";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        title: []const u8,
    };
    pub const Out = struct {
        id: []const u8,
        status: []const u8,
        /// Waiting for someone who may publish.
        pending: bool,
        /// Whether the plugin may put it live itself.
        publish: bool,
    };
    pub const example: In = .{
        .title = "Apples 2.40",
    };
    pub const example_out: Out = .{
        .id = "0190a1b2c3d40001a1b2c3d4",
        .status = "published",
        .pending = false,
        .publish = true,
    };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now().ms >= 0);

        if (in.title.len == 0 or in.title.len > 200) {
            return error.Invalid;
        }

        const document = std.json.Stringify.valueAlloc(ctx.arena(), .{
            .title = in.title,
        }, .{}) catch return error.OutOfMemory;
        const created = try ctx.call(record.Create, .{
            .type = "note",
            .document = document,
        });
        const moved = try ctx.call(record.Transition, .{
            .id = created.id,
            .transition = "publish",
        });

        return .{
            .id = created.id,
            .status = moved.status,
            .pending = moved.pending,
            .publish = ctx.grant("records.write").publish,
        };
    }
};

pub const plugin = publr.plugin.define(manifest, .{
    .operations = operations,
    .permissions = &.{.{
        .key = "records.write",
        .records = &.{"note"},
        .publish = true,
        .reason = "Puts new prices live",
    }},
});
