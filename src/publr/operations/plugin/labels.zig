//! Plugins' names as people read them, in the caller's language: what a plugin shows where
//! another plugin did something (an order's timeline), and the admin beside what a plugin
//! draws.
const operation = @import("../../operation.zig");

pub const Named = struct {
    name: []const u8,
    label: []const u8,
};

pub const Labels = struct {
    pub const name = "plugin.labels";
    /// Changes nothing and tells only what every admin page shows: a plugin's code acting
    /// for anyone may ask.
    pub const open = true;
    pub const description = "Name plugins as people read them";
    pub const details =
        \\Each plugin named, compiled in or installed, as people read it: the words its
        \\summary opens with (`Bank transfer: ...` is "Bank transfer"), in the caller's
        \\language, else its name. A name no plugin has is answered as it was asked. Changes
        \\nothing; anyone may call it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        names: []const []const u8,
    };
    pub const Out = struct {
        labels: []const Named,
    };
    pub const example: In = .{
        .names = &.{"bank_transfer"},
    };
    pub const example_out: Out = .{
        .labels = &.{.{
            .name = "bank_transfer",
            .label = "Bank transfer",
        }},
    };
    pub const field_docs: operation.Docs(In) = .{
        .names = "The plugins, by name; at most 64",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .labels = "Each name asked, with its label",
    };
};
