//! Which providers a login page may offer: the ones compiled in whose credentials are there.
const operation = @import("../../operation.zig");

/// A provider a login page offers: "Continue with <label>".
pub const Offered = struct {
    name: []const u8,
    label: []const u8,
    /// An SVG path on a 24 by 24 canvas.
    icon: []const u8,
    /// Where "Continue with <label>" goes: `/auth/<name>`.
    path: []const u8,
};

pub const Providers = struct {
    pub const name = "identity.providers";
    pub const description = "The sign-in providers this site offers";
    pub const details =
        \\Anyone may call it: a login page asks it which buttons to show. A provider is
        \\offered when its plugin is compiled in, its client id is in the environment and every
        \\secret its plugin declares is set; one without them is left out, not broken.
        \\Nothing is written.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const In = struct {};
    pub const Out = struct {
        providers: []const Offered,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .providers = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{};
    pub const output_docs: operation.Docs(Out) = .{
        .providers = "Each offered provider, in name order: `name` (`github`), `label` " ++
            "(`GitHub`), `icon` (an SVG path on a 24 by 24 canvas) and `path` " ++
            "(`/auth/github`); empty with no provider plugin",
    };
};
