//! `design.save_system`: an app's design system, its tokens and fonts written into its
//! `app.zon` (the rest of the file kept as it is) and the structure over them into its
//! `design/system.zon`, through `apps.write`, then loaded live.
const operation = @import("../../operation.zig");
const app = @import("../../model/app.zig");

pub const SaveSystem = struct {
    pub const name = "design.save_system";
    pub const description = "Write an app's design tokens and fonts into its app.zon, live";
    pub const details =
        \\Administrators only, and not a device that may save drafts only. `tokens` replaces
        \\the app's `.tokens` and `fonts` its `.fonts`, whole; everything else in `app.zon`
        \\stays as written. A token's name is lowercase letters, digits and `-`, starting
        \\with a letter; its value one CSS value (no `;`, `{`, `}` or line break). A font is a
        \\family with an `https://` stylesheet, or the files the site hosts (`faces`, each a
        \\media path or `https://`). `system`, when given, replaces `design/system.zon`: the
        \\color roles and contexts, the font definitions, the type scale, the icons and the
        \\blocks' starting documents. Once written the apps are loaded again; when
        \\they do not load, it fails with `NotLoaded` and why, and the file stays written.
        \\Not found when no app has that `.name`.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        app: []const u8,
        /// One document: the app's tokens, `[{ "name", "value" }]`, as many as it holds.
        tokens: operation.Json = .{
            .text = "[]",
        },
        fonts: []const app.Font = &.{},
        /// One document: `design/system.zon` as JSON.
        system: ?operation.Json = null,
    };
    pub const Out = struct {
        path: []const u8,
        tokens: u32,
        fonts: u32,
        system: []const u8 = "",
    };
    pub const example: In = .{
        .app = "www",
        .tokens = .{
            .text = "[{\"name\":\"color-brand\",\"value\":\"#2f5d54\"}]",
        },
        .fonts = &.{.{
            .family = "Inter",
            .url = "https://fonts.googleapis.com/css2?family=Inter",
        }},
    };
    pub const example_out: Out = .{
        .path = "www/app.zon",
        .tokens = 1,
        .fonts = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .app = "The app's `.name`",
        .tokens = "Every token, `{name, value}`, in order: the app's whole `.tokens`",
        .fonts = "Every font, `{family, url}` or `{family, faces}`: the app's whole `.fonts`",
        .system = "The structure over the tokens: `design/system.zon`, whole; null keeps it",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .path = "The file written, `<folder>/app.zon`",
        .tokens = "How many tokens it holds now",
        .fonts = "How many fonts it holds now",
        .system = "The structure's file when one was written, `<folder>/design/system.zon`",
    };
};
