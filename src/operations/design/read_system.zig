const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/design/read_system.zig");
const registry = @import("../../server/registry.zig");
const apps = @import("../apps.zig");
const model_app = @import("../../model/app.zig");
const design_system = @import("../../model/design/system.zig");
const save = @import("system.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const System = struct {
    pub const shape = public.System;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
