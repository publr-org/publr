//! Mods: values plugins change, applied under a name (`mod.apply`, what `ctx.mod` calls),
//! built again when what a modifier answers from changed (`mod.changed`), and listed.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "mod",
    .label = "Modifiers",
    .area = .background,
    .summary = "Values plugins change: applied under a name, modified by whoever hooks it",
    .details =
    \\An owner passes a value through a name wherever it makes it (`ctx.mod("checkout.
    \\methods", methods)` in a plugin, `<type>.title` in core), shown or about to be saved,
    \\and every plugin's `publr.modify("checkout.methods", …)` changes it in turn: compiled
    \\in first, then installed, each in the order its plugin was loaded. A modifier's name
    \\may hold `*` for one part (`*.title`). Nothing is declared ahead: a name nobody
    \\modifies comes back as it went. Modifiers only read: no writes, no outside calls.
    ,
};

/// A modifier as administrators see it: whose it is, the name it takes, why.
pub const Modifier = struct {
    plugin: []const u8,
    name: []const u8,
    reason: []const u8,
};

pub const Apply = struct {
    pub const name = "mod.apply";
    pub const open = true;
    pub const description = "Pass values through every modifier of a name";
    pub const details =
        \\`values` is a JSON array; each modifier taking `name` changes them in turn, and the
        \\array comes back as the last left it. A value a modifier cannot read as its type
        \\stays as it was. A modifier that fails (out of its time, its memory or its calls,
        \\or stopped) refuses the call with `ModifierFailed`: the values never come back
        \\unchanged without a word. What `ctx.mod` calls; any plugin may.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        name: []const u8,
        values: operation.Json,
    };
    pub const Out = struct {
        values: operation.Json,
    };
    pub const example: In = .{
        .name = "checkout.methods",
        .values = .{
            .text = "[[{\"name\":\"Courier\"}]]",
        },
    };
    pub const example_out: Out = .{
        .values = .{
            .text = "[[{\"name\":\"Courier\"}]]",
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The name the values are applied under: dotted parts of a-z, 0-9 and _",
        .values = "The values, a JSON array, up to 200",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .values = "The values as the modifiers left them, a JSON array in the same order",
    };
};

pub const Changed = struct {
    pub const name = "mod.changed";
    pub const description = "Build again what was built with a name's values";
    pub const details =
        \\What a plugin calls when the data its modifier of `name` answers from changed
        \\(the site's currencies, say): pages built with the values applied under `name`
        \\are built again. Only a plugin modifying `name`; anyone else is refused.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .name = "money.currencies",
    };
    pub const example_out: Out = .{};
    pub const field_docs: operation.Docs(In) = .{
        .name = "The name the plugin modifies: dotted parts of a-z, 0-9 and _",
    };
};

pub const List = struct {
    pub const name = "mod.list";
    pub const description = "List every modifier: whose it is, the name it takes, why";
    pub const details =
        \\Compiled-in plugins' modifiers first, then installed ones, in the order they run.
        \\A name with `*` takes every name matching it part by part.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        modifiers: []const Modifier,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .modifiers = &.{
            .{
                .plugin = "greeter",
                .name = "greeter.salutation.title",
                .reason = "Shows a salutation the way a test needs to see it",
            },
            .{
                .plugin = "greeter",
                .name = "greeter.*",
                .reason = "Adds one to every number greeter's names carry, for the tests",
            },
        },
    };
    pub const output_docs: operation.Docs(Out) = .{
        .modifiers = "Each modifier: `plugin`, `name` (may hold `*`), `reason`",
    };
};
