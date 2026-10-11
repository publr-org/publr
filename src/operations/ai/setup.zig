//! Setting a provider up from Settings › AI: the providers the official plugins offer (until
//! the marketplace, a folder of them named by `PUBLR_PLUGIN_CATALOG`), one installed from
//! there in a click, and a test call to the one chosen.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const environment = @import("../../lib/environment.zig");
const lib_ai = @import("../../lib/ai.zig");
const sdk_ai = @import("../../sdk/ai.zig");
const providers = @import("providers.zig");
const lifecycle = @import("../plugin/lifecycle.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Catalog, SetUp, Test };

pub const catalog_variable = "PUBLR_PLUGIN_CATALOG";
const catalog_bytes_max: u32 = 64 << 10;

pub const Offered = struct {
    name: []const u8,
    label: []const u8,
    summary: []const u8,
    /// Whether it is installed already.
    installed: bool,
};

const CatalogFile = struct {
    plugins: []const struct {
        name: []const u8,
        label: []const u8,
        summary: []const u8 = "",
        kind: []const u8 = "",
        /// The built module, relative to the catalog's folder.
        module: []const u8 = "",
    } = &.{},
};

pub const Catalog = struct {
    pub const name = "ai.catalog";
    pub const description = "List the model providers that can be set up in a click";
    pub const details =
        \\The official provider plugins, from the folder `PUBLR_PLUGIN_CATALOG` names (its
        \\`catalog.json`), each marked when it is installed already. Empty when no folder is
        \\named. Administrators only.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        offered: []const Offered,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .offered = &.{},
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(@sizeOf(In) == 0);

        _ = in;

        const folder = environment.get(catalog_variable) orelse return .{
            .offered = &.{},
        };
        const file = try read_catalog(ctx, folder);
        var offered: std.ArrayList(Offered) = .empty;

        for (file.plugins) |plugin| {
            if (!std.mem.eql(u8, plugin.kind, "ai_provider")) {
                continue;
            }

            offered.append(ctx.arena, .{
                .name = plugin.name,
                .label = plugin.label,
                .summary = plugin.summary,
                .installed = try providers.find(ctx, plugin.name) != null,
            }) catch return error.OutOfMemory;
        }

        return .{
            .offered = offered.items,
        };
    }
};

pub const SetUp = struct {
    pub const name = "ai.set_up";
    pub const description = "Install a model provider from the official plugins, in a click";
    pub const details =
        \\Adds the provider's built module from the catalog as an installed plugin, as
        \\uploading its `.wasm` does: added, not yet running, until an administrator reviews
        \\what it asks for (sending requests out, its key) and enables it. Administrators
        \\only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = lifecycle.Added;
    pub const example: In = .{
        .name = "ai_example",
    };
    pub const example_out: Out = .{
        .name = "ai_example",
        .version = "0.1.0",
        .update = false,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The provider plugin's name",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const folder = environment.get(catalog_variable) orelse return ctx.fail(no_catalog);
        const file = try read_catalog(ctx, folder);

        for (file.plugins) |plugin| {
            if (!std.mem.eql(u8, plugin.name, in.name)) {
                continue;
            }

            const inside = plugin.module.len > 0 and !std.fs.path.isAbsolute(plugin.module) and
                std.mem.indexOf(u8, plugin.module, "..") == null;

            if (!inside) {
                return ctx.fail(no_module);
            }

            const path = std.fs.path.join(ctx.arena, &.{ folder, plugin.module }) catch {
                return error.OutOfMemory;
            };

            return lifecycle.add(ctx, try lifecycle.stage(ctx, path, true));
        }

        return error.NotFound;
    }
};

const no_module: sdk.operation.Failure = .{
    .name = "NoModule",
    .status = 409,
    .message = "The catalog names no built module for it",
};

pub const Test = struct {
    pub const name = "ai.test";
    pub const description = "Ask a provider for one short answer, to check it works";
    pub const details =
        \\One small request with the provider's key: `ok` when it answered, else what went
        \\wrong in its words. The server waits for the answer, a second or two.
        \\Administrators only.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        provider: []const u8,
        model: []const u8 = "",
    };
    pub const Out = struct {
        ok: bool,
        reply: []const u8,
    };
    pub const example: In = .{
        .provider = "ai_example",
    };
    pub const example_out: Out = .{
        .ok = true,
        .reply = "OK",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .provider = "The plugin that provides it",
        .model = "One of its models; empty for its default",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.provider.len == 0 or in.provider.len > 64) {
            return error.Invalid;
        }

        _ = try providers.find(ctx, in.provider) orelse return error.NotFound;

        const asked = [_]lib_ai.Message{.{
            .role = .user,
            .parts = &.{lib_ai.Part.of_text("Reply with the single word OK.")},
        }};
        const request = lib_ai.request_json(ctx.arena, .{
            .model = in.model,
            .messages = &asked,
            .output_tokens_max = 16,
        }) catch return error.OutOfMemory;
        const input = std.json.Stringify.valueAlloc(ctx.arena, sdk_ai.Completion.In{
            .request = request,
        }, .{}) catch return error.OutOfMemory;
        const operation = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{
            in.provider,
            sdk_ai.complete_verb,
        }) catch return error.OutOfMemory;
        const SDK = @import("../../server/registry.zig").SDK;
        const output = SDK.call_json(ctx, operation, input) catch |err| {
            const failure = if (ctx.failure) |found| found.message else @errorName(err);

            ctx.failure = null;

            return .{
                .ok = false,
                .reply = failure,
            };
        };

        return .{
            .ok = true,
            .reply = try reply_of(ctx, output),
        };
    }
};

fn reply_of(ctx: *Ctx, output: []const u8) Error![]const u8 {
    std.debug.assert(output.len > 0);

    const out = std.json.parseFromSliceLeaky(sdk_ai.Completion.Out, ctx.arena, output, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;
    const response = lib_ai.response_of(ctx.arena, out.response) catch return error.Invalid;

    for (response.parts) |part| {
        if (part.kind == .text) {
            return part.text orelse "";
        }
    }

    return "";
}

const no_catalog: sdk.operation.Failure = .{
    .name = "NoCatalog",
    .status = 409,
    .message = "No folder of official plugins is known: set PUBLR_PLUGIN_CATALOG",
};

fn read_catalog(ctx: *Ctx, folder: []const u8) Error!CatalogFile {
    std.debug.assert(folder.len > 0);
    std.debug.assert(catalog_bytes_max > 0);

    const path = std.fs.path.join(ctx.arena, &.{ folder, "catalog.json" }) catch {
        return error.OutOfMemory;
    };
    const limit: std.Io.Limit = .limited(catalog_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, limit) catch {
        return ctx.fail(no_catalog);
    };

    return std.json.parseFromSliceLeaky(CatalogFile, ctx.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch error.Invalid;
}
