//! One implementation of document CRUD for both domains. A `Domain` is the record domain
//! or the term domain: the same create/get/save/list/transition bodies, the same
//! definition bodies, over the domain's own tables. `operations/record.zig` and
//! `operations/term.zig` declare the operations and add what only their domain has.

const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");

pub const Def = store.definitions.Def;
pub const Row = store.definitions.Row;

pub const Config = struct {
    /// The operation namespace of the documents: `record`, `term`.
    namespace: []const u8,
    /// The operation namespace of the definitions: `content_type`, `taxonomy`.
    definition_namespace: []const u8,
    /// What the documents are called in messages: `record`, `term`.
    noun: []const u8,
    documents: type,
    values: type,
    definitions: type,
    /// What the domain refuses before a document is created under a definition.
    check_create: fn (ctx: *sdk.Ctx, row: Row) sdk.Error!void,
    /// The domain's own rules over a definition, on top of the shared ones.
    check_def: fn (ctx: *sdk.Ctx, def: Def, problems: *model.field.Problems) sdk.Error!void,
    /// The domain's own rules over a document about to be written, after validation.
    check_document: fn (ctx: *sdk.Ctx, def: Def, document: std.json.Value) sdk.Error!void,
    /// A definition as read: what the domain adds to it (the record domain appends the
    /// implicit `terms` field of every taxonomy that applies).
    expand_def: fn (ctx: *sdk.Ctx, row: Row) sdk.Error!Row,
    /// A definition as given: what the domain takes away before it is checked and stored
    /// (the implicit fields, which are never stored).
    prepare_def: fn (ctx: *sdk.Ctx, def: Def) sdk.Error!Def,
};

pub fn Domain(comptime domain_config: Config) type {
    return struct {
        pub const config = domain_config;
        pub const documents = config.documents;
        pub const values = config.values;
        pub const definitions = config.definitions;
        pub const namespace = config.namespace;
        pub const depend_prefix = config.namespace ++ ":";

        pub const access = @import("document/access.zig").Of(@This());
        pub const document = @import("document/document.zig").Of(@This());
        pub const lifecycle = @import("document/lifecycle.zig").Of(@This());
        pub const crud = @import("document/crud.zig").Of(@This());
        pub const listed = @import("document/listed.zig").Of(@This());
        pub const definition = @import("document/definition.zig").Of(@This());

        /// `record.created`, `term.published`: the notice names of the domain.
        pub fn notice_name(comptime verb: []const u8) []const u8 {
            comptime std.debug.assert(verb.len > 0);
            comptime std.debug.assert(namespace.len > 0);

            return namespace ++ "." ++ verb;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
