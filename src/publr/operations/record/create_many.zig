//! Many records of one type made at once, each as `record create` makes it, in one write:
//! seeding a site, importing from elsewhere. A batch is all or nothing.
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

pub const CreateMany = struct {
    pub const name = "record.create_many";
    pub const description = "Create many records of a type at once, from a list of documents";
    pub const details =
        \\Each document is made as `record create` makes it, its checks, hooks and events
        \\included, all in one write: up to 200 a call (`publr seed` sends a file of any size
        \\in calls of 200). The batch is all or nothing: one document refused refuses them all,
        \\its problems named `documents.<index>.<field>`. With `publish`, each is published
        \\as `record transition --transition publish` would, once all are made.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        /// The documents, each as `record create` takes one.
        documents: []const operation.Json,
        publish: bool = false,
    };
    pub const Out = struct {
        created: u32,
        ids: []const []const u8,
    };
    pub const example: In = .{
        .type = "post",
        .documents = &.{
            .{
                .text = "{\"title\":\"First\",\"body\":\"One\"}",
            },
            .{
                .text = "{\"title\":\"Second\"}",
            },
        },
    };
    pub const example_out: Out = .{
        .created = 2,
        .ids = &.{ record.example_id, record.example_changed_id },
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "The content type, by handle or id",
        .documents = "The documents, each an object as `record create` takes one, at most 200",
        .publish = "Publish each one once all are made",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .created = "How many records were made",
        .ids = "Their ids, in the documents' order",
    };
};
