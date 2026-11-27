//! Whether an installed plugin fits this Publr: built with this release or an earlier one,
//! and calling nothing of core's or a built-in plugin's that this release lacks. Checked as
//! it is installed, and again each time it is loaded.
const operation = @import("../../operation.zig");

/// An item on its way out (`call`, `event`, `mod`), as a release's migration prompt and
/// roadmap say it.
pub const Deprecation = struct {
    kind: []const u8 = "call",
    name: []const u8,
    since: []const u8,
    removed_on: []const u8,
    instead: []const u8 = "",
    migration: []const u8,
};

pub const Surface = struct {
    pub const name = "plugin.surface";
    pub const description = "List what this Publr offers plugins: operations, events, mods";
    pub const details =
        \\Anyone signed in. What a plugin built for this Publr may use, by name: the operations
        \\of core and of the built-in plugins (`call:`; each is an event too), the functions
        \\the sandbox gives a module (`host:`), core's events (`event:`, which a plugin emits
        \\or hooks: `emit:`, `hook:` in its `uses`), the mods core applies by name (`mod:`)
        \\and what an app's templates use (`template:`: functions, directives, attributes,
        \\settings).
        \\A plugin's manifest lists what it uses and the Publr it was built with
        \\(`minimum_publr`); one using what this list lacks in a namespace of core's, or built
        \\with a later Publr, is refused as it is installed and as it is loaded. `deprecated`
        \\names each item on its way out, its kind, the day it goes and what to change.
        \\Changes nothing.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        limit: u32 = 200,
        offset: u32 = 0,
    };
    pub const Out = struct {
        publr: []const u8,
        offered: []const []const u8,
        deprecated: []const Deprecation = &.{},
        more: bool = false,
    };
    pub const field_docs: operation.Docs(In) = .{
        .limit = "How many to list; 200 when omitted, up to 200",
        .offset = "How many to pass over first: operations, host functions, events, mods",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .publr = "This Publr's release",
        .offered = "What a plugin or app may use: `call:<operation>`, `host:<function>`, " ++
            "`event:<event>`, `mod:<mod>`, `template:<feature>`",
        .deprecated = "Each item on its way out, on every page: `kind`, `since`, `removed_on`, " ++
            "`instead`, `migration`",
        .more = "Whether more follow past this page",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .publr = "0.8.3",
        .offered = &.{ "call:money.text", "host:publr_emit" },
        .more = true,
    };
};
