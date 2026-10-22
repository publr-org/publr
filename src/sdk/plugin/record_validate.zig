//! A record's own `validate`, run on every write of its type whoever writes: two hooks of the
//! plugin's own, after the create and the save of its kind of record, read the record as
//! written and refuse with its problems, so the write rolls back. Hooks reach installed
//! plugins too.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const record_operations = @import("../../operations/record.zig");
const internal_operations = @import("../../operations/internal.zig");
const operation_define = @import("operation_define.zig");
const PluginCtx = @import("context.zig").PluginCtx;

/// The hooks a record's `.validate` brings: none without one.
pub fn hooks_of(comptime Definition: type) []const type {
    comptime {
        std.debug.assert(Definition.type_name.len > 0);

        if (!@hasField(@TypeOf(Definition.given), "validate")) {
            return &.{};
        }

        const Hooks = Checks(Definition);

        return &.{ Hooks.OnCreate, Hooks.OnSave };
    }
}

fn Checks(comptime Definition: type) type {
    const internal = Definition.is_internal;
    const Operations = if (internal) internal_operations else record_operations;
    const name = Definition.stored_name;
    const reason_words = "Checks each " ++ Definition.type_name ++ " record as it is written";

    return struct {
        pub const OnCreate = struct {
            pub const stage: sdk.middleware.Stage = .after;
            pub const operation = Operations.Create.name;
            pub const reason = reason_words;

            pub fn run(
                ctx: *PluginCtx,
                in: *Operations.Create.In,
                out: *const Operations.Create.Out,
            ) sdk.Error!void {
                std.debug.assert(out.id.len > 0);

                if (!std.mem.eql(u8, if (internal) in.kind else in.type, name)) {
                    return;
                }

                return check(ctx, out.id);
            }
        };

        pub const OnSave = struct {
            pub const stage: sdk.middleware.Stage = .after;
            pub const operation = Operations.Save.name;
            pub const reason = reason_words;

            pub fn run(
                ctx: *PluginCtx,
                in: *Operations.Save.In,
                out: *const Operations.Save.Out,
            ) sdk.Error!void {
                std.debug.assert(in.id.len > 0);
                std.debug.assert(out.version >= 1);

                if (internal and !std.mem.eql(u8, in.kind, name)) {
                    return;
                }

                return check(ctx, in.id);
            }
        };

        /// The record as written, checked; another type's record is none of this hook's.
        fn check(ctx: *PluginCtx, id: []const u8) sdk.Error!void {
            std.debug.assert(id.len > 0);

            const held = Definition.get(ctx, id, .{}) catch |err| switch (err) {
                error.NotFound => return,
                else => |other| return other,
            };
            var problems: operation_define.Problems(Definition.Doc) = .{};

            Definition.given.validate(held.value, &problems);

            if (!problems.is_empty()) {
                return problems.refuse(ctx);
            }
        }
    };
}
