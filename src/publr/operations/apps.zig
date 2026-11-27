//! The project's apps as files, for an agent with no file system of its own (a chat app over
//! MCP): list them, read one, write one, remove one, then load them into the running server.
//! An agent next to the project edits `apps/` directly and runs `publr apps load`.
const operation = @import("../operation.zig");

/// A change to one part of a file: `apps.edit`.
pub const Edit = @import("apps/edit.zig").Edit;

/// How a file's bytes are carried: as they are when UTF-8, else base64 (an icon, an
/// image, a font), so any file fits a JSON field.
pub const Encoding = @import("../model/app.zig").FileEncoding;

/// A file of the project's apps and its size.
pub const Entry = struct {
    path: []const u8,
    bytes: u64,
};

pub const namespace: operation.Namespace = .{
    .name = "apps",
    .label = "Apps",
    .area = .site,
    .summary = "The project's apps as files, for agents with no file system",
    .details =
    \\Each app is a folder in the project's `apps/` (`apps/<name>/app.zon` and its
    \\templates). `apps files` lists them, `apps read` and `apps write` take one file as
    \\text, `apps remove` deletes one, and `apps load` reads them into the running server,
    \\answering why they do not load when they do not. A write changes the live site, so
    \\a device allowed only drafts may not make one. Administrators only. With `publr
    \\serve` running they act on its apps, else on the project's `apps/`.
    ,
};

pub const Files = struct {
    pub const name = "apps.files";
    pub const description = "Every file of the project's apps";
    pub const details =
        \\Administrators only. Paths are `<app>/<path>`, sorted, a page at a time: `next`
        \\continues it. `prefix` keeps those whose paths start with it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        prefix: []const u8 = "",
        after: []const u8 = "",
    };
    pub const Out = struct {
        files: []const Entry,
        next: []const u8 = "",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .files = &.{
            .{
                .path = "www/app.zon",
                .bytes = 112,
            },
            .{
                .path = "www/content/index.publr",
                .bytes = 640,
            },
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .prefix = "Only paths starting with it (`www/design/`); every path when left out",
        .after = "The page after this path: the `next` the last page answered",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .files = "Of the first 4096 files found",
        .next = "The next page's `after`; empty after the last",
    };
};

pub const Read = struct {
    pub const name = "apps.read";
    pub const description = "One file of the project's apps";
    pub const details = "Administrators only. Not found when there is no such file.";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        path: []const u8,
    };
    pub const Out = struct {
        path: []const u8,
        content: []const u8,
        encoding: Encoding = .text,
    };
    pub const example: In = .{
        .path = "www/content/index.publr",
    };
    pub const example_out: Out = .{
        .path = "www/content/index.publr",
        .content = "<h1>Hi</h1>\n",
    };
    pub const field_docs: operation.Docs(In) = .{
        .path = "`<app>/<path>`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .path = "The file",
        .content = "What it holds, up to 1 MiB",
        .encoding = "`text`, or `base64` for a file that is not UTF-8 (an icon, an image)",
    };
};

pub const Write = struct {
    pub const name = "apps.write";
    pub const description = "Write one file of the project's apps; `apps load` makes it live";
    pub const details =
        \\Administrators only. Creates the file and its folders, or replaces it: up to 1 MiB,
        \\as UTF-8 text, or as base64 with `encoding` `base64` for any other file (an icon,
        \\an image, a font). It changes what visitors see once loaded, so a device that may
        \\save drafts only is refused.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        path: []const u8,
        content: []const u8,
        encoding: Encoding = .text,
    };
    pub const Out = struct {
        path: []const u8,
        bytes: u64,
    };
    pub const example: In = .{
        .path = "www/content/index.publr",
        .content = "<h1>Hi</h1>\n",
    };
    pub const example_out: Out = .{
        .path = "www/content/index.publr",
        .bytes = 12,
    };
    pub const field_docs: operation.Docs(In) = .{
        .path = "`<app>/<path>`",
        .content = "The whole file, as text or base64",
        .encoding = "`text` (the default), or `base64` for a file that is not UTF-8",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .path = "The file",
        .bytes = "Its size",
    };
};

pub const Remove = struct {
    pub const name = "apps.remove";
    pub const description = "Delete one file of the project's apps into the trash";
    pub const details =
        \\Administrators only, and not a device that may not publish. Not found when
        \\there is no such file. `apps load` makes the change live.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        path: []const u8,
    };
    pub const Out = struct {
        removed: bool,
    };
    pub const example: In = .{
        .path = "www/content/old.publr",
    };
    pub const example_out: Out = .{
        .removed = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .path = "`<app>/<path>`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .removed = "Always true",
    };
};

pub const Load = struct {
    pub const name = "apps.load";
    pub const description = "Read the apps from their folder into the running server";
    pub const details =
        \\Administrators only. The apps are read again and swapped in, live at once; with
        \\no server running, they are only checked, as `serve` would load them. When they
        \\do not load, the failure says why, and a running server's apps are unavailable
        \\(the admin stays up) until a load succeeds.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        loaded: bool,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .loaded = true,
    };
    pub const field_docs: operation.Docs(In) = .{};
    pub const output_docs: operation.Docs(Out) = .{
        .loaded = "Always true",
    };
};
