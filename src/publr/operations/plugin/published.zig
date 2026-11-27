//! `plugin.interfaces`: each plugin's published interface on this site, the built-in ones
//! from their declarations, the installed ones from their manifests. What `plugin build`
//! builds a plugin against: each one a module under its name (`@import("payments")`).
const operation = @import("../../operation.zig");

const Interface = @import("../../published.zig").Interface;

pub const Interfaces = struct {
    pub const name = "plugin.interfaces";
    pub const description = "List each plugin's published interface: its contracts and dimensions";
    pub const details =
        \\What other plugins build against without a plugin's code: the contracts it owns,
        \\each part's input and output as shape nodes, and its dimensions with the field
        \\option and read option each offers. The built-in ones first, then the installed ones
        \\by name; a plugin publishing nothing is left out. `plugin build` reads them to build
        \\a plugin naming them in `depends_on` or `compatible_with`.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        interfaces: []const Interface,
        /// Whether more follow past this page.
        more: bool = false,
    };
    pub const field_docs: operation.Docs(In) = .{
        .limit = "How many plugins to look at; 50 when omitted, up to 200",
        .offset = "How many plugins to pass over first: the built-in ones, then the installed",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .interfaces = &.{.{
            .plugin = "payments",
            .version = "1.0.0",
            .contracts = &.{.{
                .name = "payments.method",
                .parts = &.{.{
                    .name = "start",
                    .required = true,
                    .input = &.{.{
                        .parent = -1,
                        .kind = .object,
                    }},
                    .output = &.{.{
                        .parent = -1,
                        .kind = .object,
                    }},
                }},
            }},
        }},
    };
};
