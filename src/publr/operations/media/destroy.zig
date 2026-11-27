const operation = @import("../../operation.zig");
const library = @import("library.zig");

pub const Destroy = struct {
    pub const name = "media.destroy";
    pub const description = "Delete files for good, freeing their space";
    pub const details =
        \\Each file goes with its record, its bytes and its resized copies, and nothing is kept
        \\in the trash: it can never be restored. Only a person does it, in the admin; a device
        \\lists it for its person instead. A file a record still points at is refused like any
        \\record that is referenced.
    ;
    pub const kind: operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        ids: []const []const u8,
    };
    pub const Out = struct {
        destroyed: u32,
    };
    pub const example: In = .{
        .ids = &.{library.example_item.id},
    };
    pub const example_out: Out = .{
        .destroyed = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .ids = "The files' record ids, up to 200",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .destroyed = "How many files went",
    };
};
