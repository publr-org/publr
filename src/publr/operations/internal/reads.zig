//! Reading a plugin's internal records: one by id, the first or every one matching, how many.
const operation = @import("../../operation.zig");
const internal = @import("../internal.zig");

const Item = internal.Item;
const example_id = internal.example_id;
const example_document = internal.example_document;
const example_item = internal.example_item;

pub const Get = struct {
    pub const name = "internal.get";
    pub const description = "Read one internal record";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        kind: []const u8,
        id: []const u8,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = Item;
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
        .id = example_id,
    };
    pub const example_out: Out = example_item;
    pub const field_docs: operation.Docs(In) = .{
        .kind = "The collection",
        .id = "The record",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };
};

pub const FindOne = struct {
    pub const name = "internal.find_one";
    pub const description = "The one internal record whose indexed field holds a value";
    pub const details = "Null when none does; `conflict` when two do.";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        kind: []const u8,
        field: []const u8,
        value: []const u8,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct {
        record: ?Item,
    };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
        .field = "name",
        .value = "Ada",
    };
    pub const example_out: Out = .{
        .record = example_item,
    };
    pub const field_docs: operation.Docs(In) = .{
        .kind = "The collection",
        .field = "An indexed field",
        .value = "The value it holds, as text (`42`, `true`)",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };
};

pub const Find = struct {
    pub const name = "internal.find";
    pub const description = "A page of internal records, newest first";
    pub const details =
        \\With `field` and `value`, only those whose indexed field holds it. `oldest` turns
        \\the order round: the order they were made in. `fields` names the fields of each
        \\document to answer, the others left out: a list that shows two fields reads two.
        \\With `ids` (up to 200), the records of those ids instead of a page, in the order
        \\named, one that is not there left out: many records by id are one read.
        \\With `after`, a walk's page: the records after that id in id order, which is the order
        \\they were made in (`""` for the first page). Each page is found from the index, so a
        \\walk over a long list costs the same a page; `offset` is not given with it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        kind: []const u8,
        field: ?[]const u8 = null,
        value: ?[]const u8 = null,
        limit: u32 = 50,
        offset: u32 = 0,
        oldest: bool = false,
        after: ?[]const u8 = null,
        fields: []const []const u8 = &.{},
        ids: []const []const u8 = &.{},
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct {
        records: []const Item,
    };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
    };
    pub const example_out: Out = .{
        .records = &.{example_item},
    };
    pub const field_docs: operation.Docs(In) = .{
        .kind = "The collection",
        .field = "An indexed field to filter on",
        .value = "The value it holds, as text",
        .limit = "Page size, up to 200",
        .offset = "Records to skip",
        .oldest = "The oldest first, instead of the newest",
        .after = "A walk's page: the records after this id (`\"\"` for the first)",
        .fields = "The fields of each document to answer; every field when none is named",
        .ids = "The records of these ids, up to 200, instead of a page",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };
    /// The most fields one page names.
    pub const fields_max: u32 = 64;
};

pub const Count = struct {
    pub const name = "internal.count";
    pub const description = "How many internal records a collection holds";
    pub const details =
        \\With `field` and `value`, how many whose indexed field holds it. Counted from the
        \\index: no record is read, so a list can say how many there are beside the page it
        \\shows. Changes nothing.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        kind: []const u8,
        field: ?[]const u8 = null,
        value: ?[]const u8 = null,
        plugin: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = struct {
        count: u64,
    };
    pub const example: In = .{
        .plugin = "greeter",
        .kind = "visit",
    };
    pub const example_out: Out = .{
        .count = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .kind = "The collection",
        .field = "An indexed field to filter on",
        .value = "The value it holds, as text",
        .plugin = "Whose records, when no plugin is running",
        .app = "Which app's, when no plugin is running",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .count = "How many records match",
    };
};
