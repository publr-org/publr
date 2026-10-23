//! Hooks, events and other plugins' things, as plugins write them:
//! `publr.before(Sign, refuse_links)`,
//! `publr.event.define(.{ .name = "out_of_stock", .payload = Payload })`,
//! `publr.remote.operation("inventory.reserve", In, Out)`. A hook names what it hooks by
//! type: an operation (its own, core's or a remote) or an event. A plugin's own things get its
//! name in front when it is bound.
const queue = @import("queue.zig");
const std = @import("std");
const sdk = @import("../../sdk.zig");
const middleware = @import("../middleware.zig");
const PluginCtx = @import("context.zig").PluginCtx;
const record_typed = @import("../../operations/record/typed.zig");
const record_define = @import("record_define.zig");
const modify_define = @import("modify_define.zig");
const mods = @import("../mods.zig");
const error_events = @import("../error_events.zig");

const Stage = middleware.Stage;

/// `publr.before(Operation, run)`: changes or refuses the operation's input, inside its write.
/// Operations only: an event already happened (a sign-in or a transition, which may still be
/// refused, are the exceptions core names).
pub fn before(comptime Target: type, comptime run: anytype) type {
    return hook(.before, Target, run);
}

/// `publr.after(Target, run)`: inside the write, after the operation ran or the event was
/// emitted; its error refuses, rolling the write back.
pub fn after(comptime Target: type, comptime run: anytype) type {
    return hook(.after, Target, run);
}

/// `publr.on(Target, run)`: from the queue once the write committed, never in the caller's
/// request; gets the operation's answer or the event's payload as it was.
pub fn on(comptime Target: type, comptime run: anytype) type {
    return hook(.on, Target, run);
}

/// A modifier: `publr.modify("variant.title", title)` changes the value applied under that
/// name (`*` for one part: `*.title`), wherever its owner applies it.
pub fn modify(comptime name: []const u8, comptime run: anytype) type {
    comptime {
        modify_define.check_name(name);

        const Target = struct {
            pub const pattern = name;
            pub const Value = modify_define.ValueOf(run);
        };

        return hook(.modify, Target, run);
    }
}

fn hook(comptime stage: Stage, comptime Target: type, comptime run: anytype) type {
    comptime {
        std.debug.assert(stage != .pre);

        if (@typeInfo(@TypeOf(run)) != .@"fn") {
            @compileError("a hook takes a named function: `publr." ++ @tagName(stage) ++
                "(Target, run)`");
        }

        if (stage != .on and is_event(Target) and error_events.on_only(Target.full_name)) {
            @compileError("`" ++ Target.full_name ++ "` is kept outside the write that " ++
                "raised it: hook it with `on`");
        }

        if (stage == .before and is_event(Target) and !refusable(Target)) {
            @compileError("`before` hooks an operation; an event already happened: hook it " ++
                "`after` or `on`");
        }

        return struct {
            pub const publr_hook_definition = true;
            pub const hook_stage = stage;
            pub const target = Target;
            pub const given_run = run;
        };
    }
}

fn is_event(comptime Target: type) bool {
    return @hasDecl(Target, "publr_event_definition");
}

/// Whether a `before` hook may refuse the event: only the ones core says (a sign-in, a
/// transition); a plugin's own event already happened.
fn refusable(comptime Target: type) bool {
    return @hasDecl(Target, "refusable") and Target.refusable;
}

pub fn is_hook(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "publr_hook_definition");
}

/// The full name of what a hook targets: an operation or event of the plugin's own gets the
/// plugin's name in front; anything else already has its full name.
pub fn target_name(comptime Target: type, comptime plugin: []const u8) []const u8 {
    comptime {
        std.debug.assert(plugin.len > 0);

        if (@hasDecl(Target, "publr_operation_definition")) {
            return plugin ++ "." ++ Target.verb;
        }

        if (is_event(Target)) {
            return if (Target.full_name.len > 0) Target.full_name else plugin ++ "." ++ Target.verb;
        }

        return Target.name;
    }
}

/// The hook as the core runs it.
/// `words`: the `run` function's `///`, what an administrator reads when the plugin asks
/// to hook in (`reason`, empty when it has none); a hook without one is compiled in only.
pub fn Described(
    comptime Definition: type,
    comptime plugin: []const u8,
    comptime words: ?[]const u8,
) type {
    comptime {
        const Target = Definition.target;
        const given_run = Definition.given_run;
        const text = words orelse "";

        if (Definition.hook_stage == .modify) {
            return struct {
                pub const stage: Stage = .modify;
                pub const pattern = Target.pattern;
                pub const reason = text;

                pub fn run(ctx: *PluginCtx, batch: *mods.Batch) sdk.Error!void {
                    return modify_define.run_batch(Target.Value, given_run, ctx, batch);
                }
            };
        }

        const name = target_name(Target, plugin);

        if (is_event(Target) and Definition.hook_stage != .on) {
            return EventHook(Definition.hook_stage, Target, name, text, given_run);
        }

        return switch (Definition.hook_stage) {
            .before => struct {
                pub const stage: Stage = .before;
                pub const operation = name;
                pub const reason = text;
                pub const run = given_run;
            },
            .after => struct {
                pub const stage: Stage = .after;
                pub const operation = name;
                pub const reason = text;
                pub const run = given_run;
            },
            // An event's payload, or an operation's answer: what the hook gets from the queue.
            .on => struct {
                pub const stage: Stage = .on;
                pub const event = name;
                pub const Payload = if (is_event(Target)) Target.Payload else Target.Out;
                pub const reason = text;

                pub fn run(ctx: *PluginCtx, payload: Payload) sdk.Error!void {
                    return queued(given_run, ctx, payload);
                }
            },
            else => @compileError("hook stage " ++ @tagName(Definition.hook_stage)),
        };
    }
}
/// A `before` or `after` hook on an event (core's sign-in, a transition, a plugin's own): the
/// plugin's `fn (ctx, payload)` run inside the write that emitted it, its error refusing it.
/// Shaped as an operation hook named for the event, so installed plugins run it the same way.
fn EventHook(
    comptime hook_stage: Stage,
    comptime Target: type,
    comptime name: []const u8,
    comptime text: []const u8,
    comptime given_run: anytype,
) type {
    comptime {
        std.debug.assert(name.len > 0);
        std.debug.assert(hook_stage == .before or hook_stage == .after);

        const Payload_ = Target.Payload;
        const Nothing = struct {};

        if (hook_stage == .before) {
            return struct {
                pub const stage: Stage = .before;
                pub const operation = name;
                pub const event = name;
                pub const Payload = Payload_;
                pub const reason = text;

                pub fn run(ctx: *PluginCtx, in: *Payload) sdk.Error!void {
                    return given_run(ctx, in.*);
                }
            };
        }

        return struct {
            pub const stage: Stage = .after;
            pub const operation = name;
            pub const event = name;
            pub const Payload = Payload_;
            pub const reason = text;

            pub fn run(ctx: *PluginCtx, in: *Payload, _: *const Nothing) sdk.Error!void {
                return given_run(ctx, in.*);
            }
        };
    }
}

/// An `on` hook is queued work, run from the queue once the write committed: its `run`
/// takes `*publr.QueueCtx` (with `fetch`).
fn queued(comptime given: anytype, ctx: *PluginCtx, value: anytype) sdk.Error!void {
    const First = @typeInfo(@TypeOf(given)).@"fn".params[0].type.?;

    if (comptime First != *queue.Queue(PluginCtx)) {
        @compileError("an `on` hook is queued work: its run takes `*publr.QueueCtx`");
    }

    var queue_ctx: queue.Queue(PluginCtx) = .{
        .base = ctx,
    };

    std.debug.assert(queue_ctx.base == ctx);

    return given(&queue_ctx, value);
}

/// `publr.event.define(.{ .name = "out_of_stock", .payload = struct { ... } })`: something
/// that happens that is not a call. Emitted with `ctx.emit(OutOfStock, payload)`, listed in
/// `.events`, hooked with `publr.after` or `publr.on`; `.Payload` names its type. A plugin's
/// name has no dot (the plugin's goes in front); core's is its full name (`auth.signed_in`).
pub fn event(comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        if (!@hasField(Options, "name") or !@hasField(Options, "payload")) {
            @compileError("an event is `publr.event.define(.{ .name, .payload })`");
        }

        const name: []const u8 = options.name;
        const Payload_: type = options.payload;

        if (name.len == 0 or @typeInfo(Payload_) != .@"struct") {
            @compileError("an event needs a name and a struct payload: " ++ name);
        }

        const core = std.mem.indexOfScalar(u8, name, '.') != null;
        const refusable_ = @hasField(Options, "refusable") and options.refusable;

        if (refusable_ and !core) {
            @compileError("only core names an event a `before` hook may refuse: " ++ name);
        }

        return struct {
            pub const publr_event_definition = true;
            pub const Payload = Payload_;
            pub const verb = name;
            pub const full_name = if (core) name else "";
            pub const refusable = refusable_;
        };
    }
}

/// Another plugin's things, described with only what this plugin uses.
pub const remote = struct {
    /// Another plugin's operation, as this plugin uses it: its name, what this plugin sends
    /// and the part of the answer it reads. Listed in the plugin's `remotes`, it is called
    /// (`ctx.call(Reserve, ...)`) and hooked like any operation; its plugin must be named in
    /// `depends_on` or `compatible_with`. Checked against the real operation when both are
    /// compiled in, and when either is installed.
    pub fn operation(
        comptime operation_name: []const u8,
        comptime Input: type,
        comptime Output: type,
    ) type {
        comptime sdk.operation.assert_name(operation_name);

        return struct {
            pub const name = operation_name;
            pub const In = Input;
            pub const Out = Output;
            pub const remote = true;
        };
    }

    /// Another plugin's record type: `publr.remote.record("products.variant", Fields)`.
    pub fn record(comptime name: []const u8, comptime Fields: type) type {
        comptime {
            if (std.mem.indexOfScalar(u8, name, '.') == null) {
                @compileError("a remote record is named `<plugin>.<type>`");
            }

            const Typed = record_define.Store(Fields, name, false);

            return struct {
                pub const remote_record = name;
                pub const fields_used = @import("remote_fields.zig").of(name, Fields);
                pub const Doc = Fields;
                pub const Held = Typed.Item;
                pub const Ref = record_typed.Ref(Fields, name);

                /// The one record whose unique `field` holds `value`, or null.
                pub fn find_one(
                    any_ctx: anytype,
                    comptime field: std.meta.FieldEnum(Fields),
                    value: anytype,
                ) sdk.Error!?Held {
                    return Typed.find_one(queue.base_of(any_ctx), @tagName(field), value);
                }

                /// The record, its pending changes included; not found in the trash unless
                /// `.{ .trashed = true }`.
                pub fn get(
                    any_ctx: anytype,
                    id: []const u8,
                    options: record_define.GetOptions,
                ) sdk.Error!Held {
                    return record_define.get_typed(Typed, any_ctx, id, options);
                }

                /// Moves the record by a transition of its owner's flow, or one this plugin
                /// added to it (`.register_statuses`), by name.
                pub fn transition(
                    any_ctx: anytype,
                    held: Held,
                    comptime named: @TypeOf(.enum_literal),
                ) sdk.Error!record_define.Transitioned {
                    return record_define.transition_named(any_ctx, held.id, @tagName(named));
                }
            };
        }
    }

    /// Another plugin's event: `publr.remote.event("inventory.out_of_stock", Payload)`,
    /// hooked with `publr.after` or `publr.on`; or an operation's, whose payload is its answer.
    pub fn event(comptime name: []const u8, comptime Payload_: type) type {
        comptime {
            if (std.mem.indexOfScalar(u8, name, '.') == null) {
                @compileError("a remote event is named `<plugin>.<event>`");
            }

            std.debug.assert(@typeInfo(Payload_) == .@"struct");

            return struct {
                pub const publr_event_definition = true;
                pub const remote_event = name;
                pub const Payload = Payload_;
                pub const verb = name;
                pub const full_name = name;
            };
        }
    }
};

test "a hook on a plugin's own operation is named for the plugin" {
    const Definition = struct {
        pub const publr_operation_definition = true;
        pub const verb = "sign";
    };
    const Refuse = before(Definition, struct {
        fn run(_: *PluginCtx, _: *u8) sdk.Error!void {}
    }.run);
    const Hook = Described(Refuse, "guestbook", "Refuses links");
    const Unexplained = Described(Refuse, "guestbook", null);

    try std.testing.expectEqualStrings("guestbook.sign", Hook.operation);
    try std.testing.expectEqual(Stage.before, Hook.stage);
    try std.testing.expectEqualStrings("Refuses links", Hook.reason);
    try std.testing.expectEqualStrings("", Unexplained.reason);

    const Stock = event(.{
        .name = "out_of_stock",
        .payload = struct {
            variant: []const u8,
        },
    });

    const stock_name = comptime target_name(Stock, "inventory");

    try std.testing.expectEqualStrings("inventory.out_of_stock", stock_name);
}
