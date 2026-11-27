//! `design.system`: an app's design system as it is written, its `app.zon` tokens and fonts
//! and the structure in its `design/system.zon`; what the design system builder opens on.
const operation = @import("../../operation.zig");
const app = @import("../../model/app.zig");

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
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        app: []const u8,
    };
    pub const Out = struct {
        /// One document: every token, `[{ "name", "value" }]`.
        tokens: operation.Json,
        fonts: []const app.Font,
        /// One document: `design/system.zon` as JSON, or null.
        system: ?operation.Json,
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
    pub const field_docs: operation.Docs(In) = .{
        .app = "The app's `.name`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .tokens = "Every token `app.zon` declares, in order",
        .fonts = "Every font `app.zon` declares: a stylesheet, or hosted faces",
        .system = "The structure `design/system.zon` holds, or null",
        .saved = "Whether `design/system.zon` exists",
    };
};
