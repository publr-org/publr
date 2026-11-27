//! `record.query`: a GROQ query (GROQ-1.revision5) over the content. The engine evaluates
//! it; the records it reads come through `record.list` as the caller may read them
//! (`query_dataset.zig`), narrowed by what the query's filters say.
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

pub const Problem = struct {
    /// The record a reference points at.
    id: []const u8,
    /// `status` (not in the statuses read), `owner` (not the caller's own), `type` (a type
    /// out of reach).
    reason: []const u8,
    message: []const u8,
};

pub const Query = struct {
    pub const name = "record.query";
    pub const description = "Ask for content with a GROQ query, nested records and all";
    pub const details =
        \\A GROQ query (GROQ-1.revision5, spec.groq.dev): `*[_type == "product" && slug ==
        \\$slug][0]{ title, "variants": *[_type == "variant" && product == ^._id] |
        \\order(price.GBP) }`. All of the language but its extensions, custom functions,
        \\delta mode and vendor functions. It reads what the caller may: the types their grant
        \\reaches (a visitor: public ones), every status the grant allows with perspective
        \\`all` (the default), each record's latest copy for a signed-in caller, or live
        \\records only with `published` (a visitor's and a site page's only one), without
        \\the fields the grant hides. A plugin
        \\reads its own internal records too (`_type == "cart.line"`), and another plugin's
        \\its `records.read` names. A query naming a type out of reach is refused as
        \\`Denied`; a reference to a record the caller may not read is `null`, listed in
        \\`problems`. References are record ids: `product == ^._id` compares them, `->`
        \\follows them. Records in the trash are left out unless `trashed` asks for them.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        query: []const u8,
        /// `$name` values, a JSON object.
        params: operation.Json = .object,
        perspective: Perspective = .all,
        /// Records in the trash too.
        trashed: bool = false,
    };
    pub const Perspective = enum { published, all };
    pub const Out = struct {
        result: operation.Json,
        /// References the caller may not follow, made `null`: which record, and why.
        problems: []const Problem = &.{},
    };
    pub const example: In = .{
        .query = "*[_type == \"post\" && slug == $slug][0]{ title }",
        .params = .{
            .text = "{\"slug\":\"hello-world\"}",
        },
    };
    pub const example_out: Out = .{
        .result = .{
            .text = "{\"title\":\"Hello, world\"}",
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .query = "The GROQ query",
        .params = "Its `$name` values, as a JSON object",
        .perspective = "`published` (live records) or `all` (every status the grant allows)",
        .trashed = "Read records in the trash too",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .result = "What the query answers: a list, one record, a value, or null",
        .problems = "Each reference made `null` because you may not read its record, and why",
    };
};
