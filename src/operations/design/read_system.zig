//! `design.system`: an app's design system as it is written, its `app.zon` tokens and fonts
//! and the structure in its `design/system.zon`; what the design system builder opens on.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const apps = @import("../apps.zig");
const model_app = @import("../../model/app.zig");
const design_system = @import("../../model/design/system.zig");
const save = @import("system.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const System = struct {
    pub const name = "design.system";
    pub const description = "Read an app's design system: tokens, fonts and the structure";
    pub const details =
        \\Administrators only. The tokens and fonts its `app.zon` declares, as written, and
        \\the structure over them its `design/system.zon` holds: color roles and contexts,
        \\font definitions, the type scale, icons and the blocks' starting documents. `system`
        \\is null when the app has none yet, or when the file is not one (`saved` says
        \\which). Not found when no app has that `.name`.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        app: []const u8,
    };
    pub const Out = struct {
        /// One document: every token, `[{ "name", "value" }]`.
        tokens: sdk.operation.Json,
        fonts: []const model_app.Font,
        /// One document: `design/system.zon` as JSON, or null.
        system: ?sdk.operation.Json,
        saved: bool,
    };
    pub const example: In = .{
        .app = "www",
    };
    // An app that declares no tokens or design system yet: the first a site has.
    pub const example_out: Out = .{
        .tokens = .{
            .text = "[]",
        },
        .fonts = &.{},
        .system = null,
        .saved = false,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .app = "The app's `.name`",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .tokens = "Every token `app.zon` declares, in order",
        .fonts = "Every font `app.zon` declares: a stylesheet, or hosted faces",
        .system = "The structure `design/system.zon` holds, or null",
        .saved = "Whether `design/system.zon` exists",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(in.app.len < 1 << 16);

        if (!model_app.valid_name(in.app)) {
            return error.Invalid;
        }

        const found = try save.find_zon(ctx, in.app);
        const config = try save.parsed(ctx.arena, found.content);
        const folder = found.path[0 .. found.path.len - "/app.zon".len];
        const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{
            folder,
            design_system.file_name,
        });
        const read = registry.SDK.dispatch(ctx, apps.Read, .{
            .path = path,
        }) catch |err| {
            return switch (err) {
                error.NotFound => answered(ctx, config, null, false),
                else => err,
            };
        };
        const structure = design_system.from_zon(ctx.arena, read.content) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Invalid => answered(ctx, config, null, true),
            };
        };

        std.debug.assert(std.mem.eql(u8, config.name, in.app));

        return answered(ctx, config, structure, true);
    }

    /// The tokens and the structure each one document, as many as the app holds.
    fn answered(
        ctx: *Ctx,
        config: anytype,
        structure: ?design_system.System,
        saved: bool,
    ) Error!Out {
        std.debug.assert(config.name.len > 0);

        const Json = sdk.operation.Json;

        return .{
            .tokens = Json.of(ctx.arena, config.tokens) catch return error.OutOfMemory,
            .fonts = config.fonts,
            .system = if (structure) |given|
                Json.of(ctx.arena, given) catch return error.OutOfMemory
            else
                null,
            .saved = saved,
        };
    }
};

test {
    _ = design_system;
}
