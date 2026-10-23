//! The providers of each contract (`publr.contract.define`), compiled in or installed: which
//! are on, and in what order the owner tries them. The administrator manages both; the
//! provider's own settings are on its plugin's page.
const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const contract = @import("../sdk/contract.zig");
const operation_define = @import("../sdk/plugin/operation_define.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "provider",
    .label = "Providers",
    .area = .system,
    .summary = "The providers of each contract: which are on, in what order",
    .details =
    \\A contract is a named set of operations providers implement (sign-in, AI models,
    \\messaging), owned by core or a plugin. Any plugin registers providers into one; the
    \\owner never names them. Each provider is on until an administrator switches it off,
    \\and the owner tries them in the order set here. A provider's own settings and
    \\secrets are on its plugin's page.
    ,
};

pub const operations = [_]type{ List, Set };

pub const Listed = struct {
    contract: []const u8,
    name: []const u8,
    plugin: []const u8,
    /// The parts it has, required and optional.
    parts: []const contract.Part,
    component: []const u8,
    on: bool,
};

pub const List = struct {
    pub const name = "provider.list";
    pub const description = "List the providers of a contract, in order, each on or off";
    pub const details =
        \\Every provider registered into `contract`, compiled in or installed, in the
        \\order the administrator set (the rest after, as registered). `can` keeps those
        \\with every optional part named; `on_only` those switched on. Administrators, and
        \\plugins listing the providers of a contract they call.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const untrusted_callers = false;
    pub const answer: ?operation_define.Answer = .plugin_calls;
    pub const open = true;
    /// Plugins and administrators: the example is an administrator's.
    pub const example_signed_in = true;
    pub const In = struct {
        contract: []const u8,
        can: []const []const u8 = &.{},
        on_only: bool = false,
    };
    pub const Out = struct {
        providers: []const contract.Registered,
        on: []const bool,
    };
    pub const example: In = .{
        .contract = "messaging",
    };
    pub const example_out: Out = .{
        .providers = &.{},
        .on = &.{},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .contract = "The contract's name: `messaging`, `ai.model`, `payments.method`",
        .can = "Optional parts every provider listed has",
        .on_only = "Only the providers switched on",
    };

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

        for (try contract.listed(ctx, in.contract)) |one| {
            if ((one.on or !in.on_only) and one.provider.has_all(in.can)) {
                try found.append(ctx.arena, one.provider);
                try on.append(ctx.arena, one.on);
            }
        }

        return .{
            .providers = found.items,
            .on = on.items,
        };
    }
};

pub const Set = struct {
    pub const name = "provider.set";
    pub const description = "Set the order of a contract's providers, and which are off";
    pub const details =
        \\`order` names providers first to last; any left out follow as registered. `off`
        \\names those switched off: the owner never calls them. Names need not be installed
        \\now: a provider installed later takes its place. Administrators only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        contract: []const u8,
        order: []const []const u8 = &.{},
        off: []const []const u8 = &.{},
    };
    pub const Out = struct {
        contract: []const u8,
    };
    pub const example: In = .{
        .contract = "messaging",
        .order = &.{"postmark"},
        .off = &.{"smtp"},
    };
    pub const example_out: Out = .{
        .contract = "messaging",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .contract = "The contract's name",
        .order = "Provider names, first to last",
        .off = "Provider names switched off",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.contract.len == 0 or in.contract.len > contract.name_len_max) {
            return error.Invalid;
        }

        if (in.order.len > contract.providers_max or in.off.len > contract.providers_max) {
            return error.Invalid;
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
