//! A plugin's remotes and what it provides others, as `plugin_contracts` checks them: built
//! from its declarations when the binary compiles, for its manifest, for the compiled-in
//! plugins the server checks installed ones against, and for the build's own check when both
//! sides are compiled in.
const std = @import("std");
const plugin_define = @import("define.zig");
const plugin_contracts = @import("../../model/plugin_contracts.zig");
const shapes = @import("../../model/contract.zig");
const versions = @import("depends_on.zig");
const hook_define = @import("hook_define.zig");

const Used = plugin_contracts.Used;
const ProvidedEvent = plugin_contracts.ProvidedEvent;
const ProvidedRecord = plugin_contracts.ProvidedRecord;
const ProvidedField = plugin_contracts.ProvidedField;

/// One remote as the manifest carries it.
pub fn used_of(comptime Remote: type) Used {
    comptime {
        if (@hasDecl(Remote, "remote_record")) {
            return .{
                .kind = .record,
                .name = Remote.remote_record,
                .fields = Remote.fields_used,
            };
        }

        if (@hasDecl(Remote, "remote_event")) {
            return .{
                .kind = .event,
                .name = Remote.remote_event,
                .output = shapes.describe(Remote.Payload),
            };
        }

        std.debug.assert(@hasDecl(Remote, "remote"));

        return .{
            .kind = .operation,
            .name = Remote.name,
            .input = shapes.describe(Remote.In),
            .output = shapes.describe(Remote.Out),
        };
    }
}

/// Every remote the plugin lists in `.remotes`.
pub fn uses_of(comptime Plugin: type) []const Used {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var list: []const Used = &.{};

        for (@import("../plugin.zig").remotes_of(Plugin)) |Remote| {
            list = list ++ &[_]Used{used_of(Remote)};
        }

        return list;
    }
}

/// The plugin as a user of others.
pub fn user_of(comptime Plugin: type) plugin_contracts.User {
    comptime {
        const contract = @import("../plugin.zig");

        return .{
            .plugin = Plugin.manifest.name,
            .depends_on = versions.of(Plugin),
            .compatible_with = contract.compatible_with_of(Plugin),
            .remotes = uses_of(Plugin),
        };
    }
}

/// The events the plugin declares in `.events`, by full name, with their payloads.
pub fn events_of(comptime Plugin: type) []const ProvidedEvent {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        if (!plugin_define.has(Plugin, "events")) {
            return &.{};
        }

        const listed: []const type = plugin_define.get(Plugin, "events");
        var list: []const ProvidedEvent = &.{};

        for (listed) |Event| {
            if (Event.full_name.len > 0) {
                @compileError(Plugin.manifest.name ++ ": an event's `.name` has no dot, " ++
                    "the plugin's name goes in front: " ++ Event.full_name);
            }

            const name = Plugin.manifest.name ++ "." ++ Event.verb;

            list = list ++ &[_]ProvidedEvent{.{
                .name = name,
                .payload = shapes.describe(Event.Payload),
            }};
        }

        return list;
    }
}

/// The plugin's record types, content and internal, with each field's kind.
pub fn records_of(comptime Plugin: type) []const ProvidedRecord {
    comptime {
        const contract = @import("../plugin.zig");
        var list: []const ProvidedRecord = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (contract.content_types_of(Plugin)) |def| {
            var fields: []const ProvidedField = &.{};

            for (def.fields) |field| {
                fields = fields ++ &[_]ProvidedField{.{
                    .name = field.name,
                    .kind = field.kind,
                    .many = field.many,
                }};
            }

            list = list ++ &[_]ProvidedRecord{.{
                .name = def.handle,
                .fields = fields,
            }};
        }

        for (contract.internal_records_of(Plugin)) |collection| {
            list = list ++ &[_]ProvidedRecord{.{
                .name = Plugin.manifest.name ++ "." ++ collection.kind,
                .fields = collection.fields,
            }};
        }

        return list;
    }
}

/// A compiled-in plugin's remote that does not fit another compiled-in plugin it only works
/// with: switched off from the start, its hooks left out of the build.
pub const Off = struct {
    plugin: []const u8,
    name: []const u8,
    why: []const u8,
};

/// Why `Remote` does not fit `Provider` compiled in beside it, in plain words, or null.
/// `declared` is how the user names it: `shelf` or `shelf@^0.1`.
pub fn misfit_compiled(
    comptime Remote: type,
    comptime Provider: type,
    comptime declared: []const u8,
) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(plugin_contracts.fields_max * 4096);

        const used = used_of(Remote);
        var operations: []const plugin_contracts.Provided = &.{};

        std.debug.assert(declared.len > 0);

        for (@import("../plugin.zig").operations_of(Provider)) |Operation| {
            if (std.mem.eql(u8, Operation.name, used.name)) {
                operations = operations ++ &[_]plugin_contracts.Provided{.{
                    .name = Operation.name,
                    .input = if (used.kind == .operation) shapes.describe(Operation.In) else &.{},
                    .output = shapes.describe(Operation.Out),
                }};
            }
        }

        const provider: plugin_contracts.Provider = .{
            .plugin = Provider.manifest.name,
            .version = Provider.manifest.version,
            .operations = operations,
            .records = records_of(Provider),
            .events = events_of(Provider),
        };
        const user: plugin_contracts.User = .{
            .plugin = "compiled",
            .depends_on = &.{},
            .compatible_with = &.{declared},
            .remotes = &.{used},
        };
        var found: [1]plugin_contracts.Finding = undefined;

        if (plugin_contracts.check(user, &.{provider}, &found) == 0) {
            return null;
        }

        var buffer: [256]u8 = undefined;
        const text = plugin_contracts.describe(found[0], &buffer);

        return text ++ "";
    }
}

/// The plugin's hooks the build keeps: all but those on its remotes that are off, which are
/// never checked against the other plugin's real shapes.
pub fn kept_hooks(
    comptime Plugin: type,
    comptime hooks: []const type,
    comptime off: []const Off,
) []const type {
    comptime {
        var kept: []const type = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (hooks) |Hook| {
            const target = if (@hasDecl(Hook, "event"))
                Hook.event
            else if (@hasDecl(Hook, "operation"))
                Hook.operation
            else
                "";

            if (!is_off(off, Plugin.manifest.name, target)) {
                kept = kept ++ &[_]type{Hook};
            }
        }

        return kept;
    }
}

/// Whether `plugin`'s remote `name` is among `off`.
pub fn is_off(off: []const Off, plugin: []const u8, name: []const u8) bool {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(off.len <= plugin_contracts.findings_max * 64);

    for (off) |each| {
        if (std.mem.eql(u8, each.plugin, plugin) and std.mem.eql(u8, each.name, name)) {
            return true;
        }
    }

    return false;
}

test "a plugin's remotes and its events, as its manifest carries them and the build checks" {
    const Provider = struct {
        pub const manifest: @import("../plugin.zig").Manifest = .{
            .name = "provider",
            .version = "1.0.0",
            .summary = "Provides a record and an event",
        };
        pub const content_types = [_]@import("../../model/content_type.zig").Def{.{
            .handle = "provider.variant",
            .name = "Variant",
            .fields = &.{
                .{
                    .name = "sku",
                    .label = "SKU",
                    .kind = "string",
                },
                .{
                    .name = "stock",
                    .label = "Stock",
                    .kind = "integer",
                },
            },
        }};
        pub const events = [_]type{Restocked};
        pub const Restocked = hook_define.event(.{
            .name = "restocked",
            .payload = struct {
                sku: []const u8,
            },
        });
    };
    const User = struct {
        pub const manifest: @import("../plugin.zig").Manifest = .{
            .name = "user_side",
            .version = "0.1.0",
            .summary = "Uses the provider",
        };
        pub const compatible_with = .{"provider@^1"};
        pub const remotes = [_]type{ Variant, Heard };
        pub const Variant = hook_define.remote.record("provider.variant", struct {
            sku: []const u8,
        });
        pub const Heard = hook_define.remote.event("provider.restocked", struct {
            sku: []const u8,
        });
    };
    const uses = comptime uses_of(User);
    const events = comptime events_of(Provider);
    const records = comptime records_of(Provider);

    try std.testing.expectEqual(@as(usize, 2), uses.len);
    try std.testing.expectEqual(plugin_contracts.Remote.record, uses[0].kind);
    try std.testing.expectEqualStrings("sku", uses[0].fields[0].name);
    try std.testing.expectEqual(plugin_contracts.Remote.event, uses[1].kind);
    try std.testing.expectEqualStrings("provider.restocked", events[0].name);
    try std.testing.expectEqualStrings("integer", records[0].fields[1].kind);

    const variant_misfit = comptime misfit_compiled(User.Variant, Provider, "provider");
    const heard_misfit = comptime misfit_compiled(User.Heard, Provider, "provider");

    try std.testing.expectEqual(null, variant_misfit);
    try std.testing.expectEqual(null, heard_misfit);
}

/// A compiled-in pair for the test below: `keeper` counts, `watcher` only works with it.
const Keeper = struct {
    pub const manifest: @import("../plugin.zig").Manifest = .{
        .name = "keeper",
        .version = "0.2.0",
        .summary = "Test plugin: counts",
    };
    pub const operations = [_]type{Count};

    pub const Count = struct {
        pub const name = "keeper.count";
        pub const description = "Count a shelf";
        pub const kind: @import("../../sdk.zig").operation.Kind = .write;
        pub const In = struct {
            aisle: u32,
        };
        pub const Out = struct {
            count: u32,
        };
        pub const example: In = .{
            .aisle = 3,
        };
        pub const example_out: Out = .{
            .count = 1,
        };

        pub fn run(
            _: *@import("context.zig").PluginCtx,
            in: In,
            _: *const @import("../../sdk.zig").Grant,
        ) @import("../../sdk.zig").Error!Out {
            std.debug.assert(in.aisle > 0);

            return .{
                .count = in.aisle,
            };
        }
    };
};

const Watcher = struct {
    pub const manifest: @import("../plugin.zig").Manifest = .{
        .name = "watcher",
        .version = "0.1.0",
        .summary = "Test plugin: watches the keeper's counts",
    };
    pub const compatible_with = .{"keeper"};
    // Keeper 0.2.0 counts by aisle, not by shelf: this remote no longer fits.
    pub const Counted = hook_define.remote.operation("keeper.count", struct {
        shelf: []const u8,
    }, struct {
        count: u32,
    });
    pub const remotes = [_]type{Counted};
    pub const middleware = [_]type{
        hook_define.Described(hook_define.after(Counted, noted), "watcher", null),
    };

    // Reads the remote's `shelf`, which keeper's real input lacks: compiled in, this would
    // not type-check, so the build must leave the hook out.
    fn noted(
        _: *@import("context.zig").PluginCtx,
        in: anytype,
        _: anytype,
    ) error{Conflict}!void {
        std.debug.assert(in.shelf.len > 0);

        return error.Conflict;
    }
};

test "compiled-in plugins that don't fit: it builds, the remote is off, its hook left out" {
    const sdk = @import("../../sdk.zig");
    const Bundle = @import("../plugin.zig").Merged(.{ Keeper, Watcher });
    const TestSDK = sdk.SDK(.{
        .operations = Bundle.merged_operations,
        .middleware = Bundle.merged_middleware,
        .operation_owners = Bundle.merged_operation_owners,
        .middleware_owners = Bundle.merged_middleware_owners,
    });
    const off = Bundle.merged_remotes_off;

    try std.testing.expectEqual(@as(usize, 1), off.len);
    try std.testing.expectEqualStrings("watcher", off[0].plugin);
    try std.testing.expectEqualStrings("keeper.count", off[0].name);
    try std.testing.expect(std.mem.startsWith(u8, off[0].why, "keeper 0.2.0: keeper.count"));
    try std.testing.expectEqual(@as(usize, 0), Bundle.merged_middleware.len);
    try std.testing.expect(is_off(off, "watcher", "keeper.count"));
    try std.testing.expect(!is_off(off, "keeper", "keeper.count"));

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const counted = try TestSDK.dispatch(&ctx, Keeper.Count, .{
        .aisle = 3,
    });

    try std.testing.expectEqual(@as(u32, 3), counted.count);
}

test "a remote that fits its compiled-in plugin is on, its hook kept" {
    const hooks = comptime kept_hooks(Watcher, &Watcher.middleware, &.{});

    try std.testing.expectEqual(@as(usize, 1), hooks.len);
    try std.testing.expect(comptime misfit_compiled(
        hook_define.remote.operation("keeper.count", struct {
            aisle: u32,
        }, struct {
            count: u32,
        }),
        Keeper,
        "keeper@^0.2",
    ) == null);
    try std.testing.expect(comptime misfit_compiled(
        hook_define.remote.operation("keeper.count", struct {
            aisle: u32,
        }, struct {
            count: u32,
        }),
        Keeper,
        "keeper@^0.1",
    ) != null);
}
