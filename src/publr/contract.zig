//! Contracts and their providers. A contract is a named set of operations providers
//! implement, owned by core or any plugin: `publr.contract.define(.{ .name, .operations,
//! .optional, .component })`, each part a struct with `In` and `Out`. A plugin registers a
//! provider with `.register_providers`, naming its own operations for the parts; the build
//! checks each against the part's shapes. The owner never names providers: it lists the
//! enabled ones, in the administrator's order, with `publr.providers(ctx, Contract, .{})`.
const std = @import("std");
const behind_of = @import("../sdk/plugin/context.zig").behind_of;
const wire_json = @import("../sdk/plugin/wire_json.zig");
const guest = @import("../sdk/plugin/guest.zig");
const sdk = @import("../sdk.zig");
const Error = @import("operation.zig").Error;
const public_of = @import("../sdk/operation.zig").public_of;
const shapes = @import("../model/contract.zig");
const public_shapes = @import("model/contract.zig");
const private = @import("../sdk/contract.zig");
const registered_model = @import("model/provider.zig");
const published_model = @import("model/published.zig");

const Registered = registered_model.Registered;
const Answers = private.Answers;

pub const name_len_max: u32 = 64;

/// Whether a contract's providers bring a UI of their own, drawn in a slot the owner leaves
/// for the chosen provider.
pub const Component = published_model.Component;

/// `publr.contract.define(.{ .name = "messaging", .operations = .{ .send = Send },
/// .optional = .{ .receipt = Receipt }, .component = .optional })`.
pub fn define(comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        for (std.meta.fieldNames(Options)) |given| {
            const known = [_][]const u8{
                "name",
                "operations",
                "optional",
                "component",
                "with",
                "at_install",
            };

            if (!private.in_list(&known, given)) {
                @compileError("contract: no option `." ++ given ++ "`");
            }
        }

        if (!@hasField(Options, "name") or !@hasField(Options, "operations")) {
            @compileError("a contract needs `.name` and `.operations`");
        }

        const name: []const u8 = options.name;

        if (name.len == 0 or name.len > name_len_max) {
            @compileError("contract `" ++ name ++ "`: `.name` is 1 to 64 characters");
        }

        const optional = if (@hasField(Options, "optional")) options.optional else .{};
        const required_parts = std.meta.fieldNames(@TypeOf(options.operations));

        if (required_parts.len == 0) {
            @compileError("contract " ++ name ++ ": `.operations` names at least one part");
        }

        for (required_parts ++ std.meta.fieldNames(@TypeOf(optional))) |part| {
            const Shape = part_type(options.operations, optional, part).?;

            if (!@hasDecl(Shape, "In") or !@hasDecl(Shape, "Out")) {
                @compileError("contract " ++ name ++ ": part `" ++ part ++ "` is a struct " ++
                    "with `In` and `Out`");
            }
        }

        const at_install: []const u8 = if (@hasField(Options, "at_install"))
            @tagName(options.at_install)
        else
            "";

        if (at_install.len > 0) {
            if (!@hasField(@TypeOf(options.operations), at_install)) {
                @compileError("contract " ++ name ++ ": `.at_install` names a required part");
            }

            const Asked = @field(options.operations, at_install).In;
            _ = @as(Asked, .{});
        }

        const component_given: Component = if (@hasField(Options, "component"))
            options.component
        else
            .none;

        if (@hasField(Options, "with") and component_given == .none) {
            @compileError("contract " ++ name ++ ": `.with` is what the owner's slot hands " ++
                "its providers' components; the contract takes no `.component`");
        }

        if (@hasField(Options, "with") and @typeInfo(options.with) != .@"struct") {
            @compileError("contract " ++ name ++ ": `.with` is a struct, one field per " ++
                "attribute the slot hands over");
        }

        return struct {
            pub const publr_contract_definition = true;
            pub const contract_name = name;
            /// The part answered at install, kept as each provider's defaults; empty for none.
            pub const install_part = at_install;
            /// Defined here, in Zig: its owner calls it with these types.
            pub const owner: []const u8 = "";
            pub const operations = options.operations;
            pub const optional_parts = optional;
            pub const component: Component = component_given;
            /// What the owner's slot hands the chosen provider's component, as data: each
            /// field an attribute of `<ProviderSlot>`; none when the contract leaves it open.
            pub const with: []const public_shapes.Node = if (@hasField(Options, "with"))
                shapes.describe(options.with)
            else
                &.{};
            /// Each part with its shapes as data, as a published interface carries them.
            pub const parts = parts_of(options.operations, optional, at_install);

            /// The part's `In` and `Out`, required or optional.
            pub fn Shape(comptime part: []const u8) type {
                return part_type(operations, optional_parts, part) orelse
                    @compileError("contract " ++ name ++ " has no part `" ++ part ++ "`");
            }

            pub fn required(comptime part: []const u8) bool {
                return @hasField(@TypeOf(operations), part);
            }
        };
    }
}

fn parts_of(
    comptime operations: anytype,
    comptime optional: anytype,
    comptime at_install: []const u8,
) []const PublishedPart {
    comptime {
        var list: []const PublishedPart = &.{};

        for (std.meta.fieldNames(@TypeOf(operations))) |part| {
            var made = part_of(@field(operations, part), part, true);

            made.at_install = std.mem.eql(u8, part, at_install);
            list = list ++ &[_]PublishedPart{made};
        }

        for (std.meta.fieldNames(@TypeOf(optional))) |part| {
            list = list ++ &[_]PublishedPart{part_of(@field(optional, part), part, false)};
        }

        if (list.len > published_model.parts_max) {
            @compileError("a contract has at most 16 parts");
        }

        const done = list;

        return done;
    }
}

fn part_of(comptime Shape: type, comptime name: []const u8, comptime required: bool) PublishedPart {
    comptime {
        std.debug.assert(name.len > 0);

        return .{
            .name = name,
            .required = required,
            .input = shapes.describe(Shape.In),
            .output = shapes.describe(Shape.Out),
        };
    }
}

pub const PublishedPart = published_model.Part;

fn part_type(
    comptime operations: anytype,
    comptime optional: anytype,
    comptime part: []const u8,
) ?type {
    comptime {
        std.debug.assert(part.len > 0);

        if (@hasField(@TypeOf(operations), part)) {
            return @field(operations, part);
        }

        if (@hasField(@TypeOf(optional), part)) {
            return @field(optional, part);
        }

        return null;
    }
}

pub fn is_contract(comptime Type: type) bool {
    comptime std.debug.assert(@sizeOf(Component) > 0);

    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "publr_contract_definition");
}

/// What the parts a caller asks for (`.{ .can = &.{.refund} }`) say, as names.
fn can_names(comptime Contract: type, comptime options: anytype) []const []const u8 {
    comptime {
        std.debug.assert(is_contract(Contract));

        var names: []const []const u8 = &.{};

        if (@hasField(@TypeOf(options), "can")) {
            for (options.can) |part| {
                const name = @tagName(part);

                _ = Contract.Shape(name);
                names = names ++ &[_][]const u8{name};
            }
        }

        return names;
    }
}

/// `publr.providers(ctx, Contract, .{ .can = &.{.refund} })`: the enabled providers of the
/// contract with those optional parts, in the administrator's order.
pub fn providers(
    ctx: anytype,
    comptime Contract: type,
    comptime options: anytype,
) Error![]const Provider(Contract) {
    comptime std.debug.assert(is_contract(Contract));

    const can = comptime can_names(Contract, options);
    const found = if (@TypeOf(ctx) == *sdk.Ctx)
        private.enabled(ctx, Contract.contract_name, can) catch |err| return public_of(err)
    else
        (try ctx.call(private.List, .{
            .contract = Contract.contract_name,
            .can = can,
            .on_only = true,
        })).providers;
    const memory = if (@TypeOf(ctx) == *sdk.Ctx) ctx.arena else ctx.arena();
    const handles = memory.alloc(Provider(Contract), found.len) catch return error.OutOfMemory;

    for (found, handles) |provider, *handle| {
        handle.* = .{
            .registered = provider,
        };
    }

    return handles;
}

/// One provider of `Contract`: `chosen.call(ctx, .send, in)` for a required part,
/// `chosen.optional(.receipt)` for an optional one, null when it lacks it.
pub fn Provider(comptime Contract: type) type {
    return struct {
        registered: Registered,

        const Self = @This();

        pub fn name(self: Self) []const u8 {
            std.debug.assert(self.registered.name.len > 0);

            return self.registered.name;
        }

        pub fn call(
            self: Self,
            ctx: anytype,
            comptime part: @TypeOf(.enum_literal),
            in: Contract.Shape(@tagName(part)).In,
        ) Error!Contract.Shape(@tagName(part)).Out {
            comptime {
                if (!Contract.required(@tagName(part))) {
                    @compileError("`" ++ @tagName(part) ++ "` is optional: call it through " ++
                        "`chosen.optional(." ++ @tagName(part) ++ ")`");
                }
            }

            const operation = self.registered.operation_of(@tagName(part)).?;

            return call_part(ctx, Contract.Shape(@tagName(part)), operation, in);
        }

        /// What the provider answered at install (the contract's `.at_install` part), as
        /// kept since: its defaults, the same until it updates.
        pub fn answers(
            self: Self,
            ctx: anytype,
        ) Error!Contract.Shape(Contract.install_part).Out {
            comptime {
                if (Contract.install_part.len == 0) {
                    @compileError("contract " ++ Contract.contract_name ++ " has no part " ++
                        "answered at install (`.at_install`)");
                }
            }

            const Out = Contract.Shape(Contract.install_part).Out;
            const core = @TypeOf(ctx) == *sdk.Ctx;
            const memory = if (core) ctx.arena else ctx.arena();
            const asked: Answers.In = .{
                .contract = Contract.contract_name,
                .provider = self.registered.name,
            };

            // An installed plugin gets the answer laid out as its own `Out`: no text read there.
            if (comptime !core and guest.mode == .sandboxed) laid: {
                const base = @import("../sdk/plugin/queue.zig").base_of(ctx);
                const Got = struct {
                    answers: Out,
                };

                // A modifier's reads are noted and answered together, as JSON.
                if (behind_of(base).reads != null) {
                    break :laid;
                }

                const api = behind_of(base);

                return (try api.read_shaped(Answers.In, Got, Answers.name, &asked)).answers;
            }

            const kept = if (core)
                try @import("../server/registry.zig").SDK.dispatch(ctx, Answers, asked)
            else
                try ctx.call(Answers, asked);

            return kept.answers.as(Out, memory) catch error.Invalid;
        }

        pub fn optional(
            self: Self,
            comptime part: @TypeOf(.enum_literal),
        ) ?Optional(Contract.Shape(@tagName(part))) {
            comptime std.debug.assert(!Contract.required(@tagName(part)));

            const operation = self.registered.operation_of(@tagName(part)) orelse return null;

            return .{
                .operation = operation,
            };
        }
    };
}

pub fn Optional(comptime Shape: type) type {
    return struct {
        operation: []const u8,

        pub fn call(self: @This(), ctx: anytype, in: Shape.In) Error!Shape.Out {
            std.debug.assert(self.operation.len > 0);

            return call_part(ctx, Shape, self.operation, in);
        }
    };
}

/// A part called through its provider's operation, by name, through the same checks as any
/// call: compiled in or installed alike.
fn call_part(
    ctx: anytype,
    comptime Shape: type,
    operation: []const u8,
    in: Shape.In,
) Error!Shape.Out {
    std.debug.assert(operation.len > 0);

    const core = @TypeOf(ctx) == *sdk.Ctx;

    // An installed plugin hands the part its input as it lies and gets the answer laid out:
    // no text written or read in the plugin.
    if (comptime !core and @hasDecl(@typeInfo(@TypeOf(ctx)).pointer.child, "call_shaped")) {
        return behind_of(ctx).call_shaped(Shape.In, Shape.Out, operation, &in);
    }

    if (comptime !core) {
        return ctx.call_named(Shape.Out, operation, in);
    }

    const memory = ctx.arena;

    const input = wire_json.stringify(memory, in) catch return error.OutOfMemory;
    const registry = @import("../server/registry.zig");
    const output = registry.SDK.call_json(ctx, operation, input) catch |err| {
        return public_of(err);
    };

    return wire_json.parse(Shape.Out, memory, output, .{}) catch error.Invalid;
}

test "a contract names its parts, required and optional" {
    const Send = struct {
        pub const In = struct {
            to: []const u8,
        };
        pub const Out = struct {
            id: []const u8,
        };
    };
    const Receipt = struct {
        pub const In = struct {
            id: []const u8,
        };
        pub const Out = struct {
            delivered: bool,
        };
    };
    const Test = define(.{
        .name = "test.mail",
        .operations = .{
            .send = Send,
        },
        .optional = .{
            .receipt = Receipt,
        },
    });

    try std.testing.expectEqualStrings("test.mail", Test.contract_name);
    try std.testing.expect(Test.required("send"));
    try std.testing.expect(!Test.required("receipt"));
    try std.testing.expect(Test.Shape("receipt") == Receipt);
    try std.testing.expectEqual(Component.none, Test.component);

    const provider: Registered = .{
        .contract = "test.mail",
        .name = "postbox",
        .parts = &.{.{
            .part = "send",
            .operation = "postbox.send",
        }},
    };

    try std.testing.expectEqualStrings("postbox.send", provider.operation_of("send").?);
    try std.testing.expect(provider.operation_of("receipt") == null);
    try std.testing.expect(provider.has_all(&.{"send"}));
    try std.testing.expect(!provider.has_all(&.{"receipt"}));
}
