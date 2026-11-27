//! Site Health's translations tab, its other half: how much of each domain's messages each
//! language translates, and by whom.
const operation = @import("../../operation.zig");

pub const Covered = struct {
    locale: []const u8,
    label: []const u8,
    /// `publr` for the core's words, a plugin's name for its own.
    domain: []const u8,
    translated: u32,
    total: u32,
    /// The plugins bringing this language's translations of the domain.
    providers: []const []const u8,
};

pub const Coverage = struct {
    pub const name = "health.coverage";
    pub const description = "How much of each domain's messages each language translates";
    pub const details =
        \\Administrators only. Each language over each domain's messages (`publr` for the
        \\core's words, a plugin's name for its own): how many it translates, of how many, and
        \\the plugins bringing them. A page of 200 at a time: `next` continues it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        after: []const u8 = "",
    };
    pub const Out = struct {
        coverage: []const Covered,
        next: []const u8 = "",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .coverage = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{
        .after = "The page after this one: the `next` the last page answered",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .coverage = "Each language over each domain's messages: how many it translates, by whom",
        .next = "The next page's `after`; empty after the last",
    };
};
