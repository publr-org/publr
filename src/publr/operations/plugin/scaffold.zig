//! A plugin to start from: a working plugin with a page of its own in the admin, made of
//! the design system's composites and reading and writing through `call` and `query`. It
//! writes nothing: its files go into `plugins/<name>/` of a site's folder on a computer,
//! where the `publr` command builds them (`publr plugin build --name <name>`).
const operation = @import("../../operation.zig");

pub const Shape = enum { list, form };

/// One file of the plugin, its path inside the plugin's folder.
pub const Source = struct {
    path: []const u8,
    content: []const u8,
};

pub const Scaffold = struct {
    pub const name = "plugin.scaffold";
    pub const description = "The files of a new plugin with a page of its own, to build";
    pub const details =
        \\Anyone signed in to the admin; writes nothing. `--page list` gives entries people
        \\add and remove, drawn in the plugin frame with the design system's composites,
        \\`call` and `query`; `--page form` one set of settings people edit, a page by
        \\declaration the admin draws itself, compiled in or installed alike. Write the
        \\files into `plugins/<name>/` of the site's folder on a computer and run
        \\`publr plugin build --name <name>` there: building needs a computer.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        name: []const u8,
        page: Shape = .list,
    };
    pub const Out = struct {
        files: []const Source,
    };
    pub const example: In = .{
        .name = "notes",
        .page = .list,
    };
    pub const example_out: Out = .{
        .files = &.{.{
            .path = "main.zig",
            .content = "//! Notes: entries people add and remove…",
        }},
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The plugin's name, `[a-z][a-z0-9_]*`",
        .page = "`list` (entries added and removed) or `form` (one set of settings)",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .files = "Every file of the plugin as `{ path, content }`, paths inside its folder",
    };
};
