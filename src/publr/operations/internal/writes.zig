//! Writing a plugin's internal records: made, saved (one or many), deleted.
const operation = @import("../../operation.zig");
const internal = @import("../internal.zig");

const Item = internal.Item;
const example_id = internal.example_id;
const example_document = internal.example_document;
const example_item = internal.example_item;

pub const Create = struct {
    pub const name = "internal.create";
    pub const description = "Keep a new internal record";
    pub const details =
        \\The document is a JSON object; its declared fields are indexed. A value breaking its
        \\field's rules is refused beside the field; a unique value another record of the
        \\collection holds is a conflict.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        kind: []const u8,
        document: operation.Json,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct {
        id: []const u8,
        version: i64,
    };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
        .document = .{
            .text = example_document,
        },
    };
    pub const example_out: Out = .{
        .id = example_id,
        .version = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .kind = "The collection, as the plugin declares it",
        .document = "The record, a JSON object",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running; the project's own when left out",
    };
};

pub const CreateMany = struct {
    pub const name = "internal.create_many";
    pub const description = "Keep many new internal records of one collection at once";
    pub const details =
        \\Each document is kept as `internal.create` keeps one, its field rules and events
        \\included, in one call: up to 200. All or nothing: one refused refuses them all,
        \\named `documents.<index>`. Answers the ids in the documents' order.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        kind: []const u8,
        documents: []const operation.Json,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct {
        ids: []const []const u8,
    };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
        .documents = &.{.{
            .text = example_document,
        }},
    };
    pub const example_out: Out = .{
        .ids = &.{example_id},
    };
    pub const field_docs: operation.Docs(In) = .{
        .kind = "The collection, as the plugin declares it",
        .documents = "The records, JSON objects, at most 200",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running; the project's own when left out",
    };
};

pub const Save = struct {
    pub const name = "internal.save";
    pub const description = "Write fields of an internal record";
    pub const details =
        \\The fields the document gives replace the record's; the others keep their values.
        \\`clear` names fields to empty: each is taken out of the record, so an optional
        \\field holds nothing again; a required one refuses the write by its rules.
        \\`expected_version` refuses a stale write. Refused on an append-only collection. The
        \\record as written runs its fields' rules, as `internal.create` does.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        kind: []const u8,
        id: []const u8,
        document: operation.Json,
        expected_version: ?i64 = null,
        clear: []const []const u8 = &.{},
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct {
        version: i64,
    };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
        .id = example_id,
        .document = .{
            .text = "{\"count\":2}",
        },
    };
    pub const example_out: Out = .{
        .version = 2,
    };
    pub const field_docs: operation.Docs(In) = .{
        .kind = "The collection",
        .id = "The record",
        .document = "The fields to write, a JSON object",
        .expected_version = "The `version` you read; refuse if it changed",
        .clear = "Fields to empty, by name: taken out of the record",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };
};

pub const SaveMany = struct {
    pub const name = "internal.save_many";
    pub const description = "Write fields of many internal records of one collection at once";
    pub const details =
        \\Each record is written as `internal.save` writes one, in one call: up to 200. All
        \\or nothing: one refused refuses them all, named `records.<index>`.
    ;
    pub const kind: operation.Kind = .write;
    pub const Written = struct {
        id: []const u8,
        document: operation.Json,
    };
    pub const In = struct {
        kind: []const u8,
        records: []const Written,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct {
        saved: u32,
    };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
        .records = &.{.{
            .id = example_id,
            .document = .{
                .text = "{\"count\":2}",
            },
        }},
    };
    pub const example_out: Out = .{
        .saved = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .kind = "The collection",
        .records = "Each record by id with the fields to write, at most 200",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };
};

pub const Delete = struct {
    pub const name = "internal.delete";
    pub const description = "Remove an internal record";
    pub const details = "Refused on an append-only collection.";
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        kind: []const u8,
        id: []const u8,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct {
        deleted: bool,
    };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
        .id = example_id,
    };
    pub const example_out: Out = .{
        .deleted = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .kind = "The collection",
        .id = "The record",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };
};
