//! `apps edit`: a change to one part of a file, not the whole file written again. A small
//! change (a word in a heading, one rule in a stylesheet) is then a few words to send.
const operation = @import("../../operation.zig");

pub const Edit = struct {
    pub const name = "apps.edit";
    pub const description = "Change one part of a file of the project's apps; `apps load` " ++
        "makes it live";
    pub const details =
        \\Administrators only. `old` must appear exactly once in the file (give enough of the
        \\text around it to make it so); it is replaced by `new`. Refused, changing nothing,
        \\when `old` is not there or is there more than once, and, like `apps write`, to a
        \\device that may save drafts only.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        path: []const u8,
        old: []const u8,
        new: []const u8,
    };
    pub const Out = struct {
        path: []const u8,
        bytes: u64,
    };
    pub const example: In = .{
        .path = "www/content/index.publr",
        .old = "<h1>Hi</h1>",
        .new = "<h1>Hello</h1>",
    };
    pub const example_out: Out = .{
        .path = "www/content/index.publr",
        .bytes = 15,
    };
    pub const field_docs: operation.Docs(In) = .{
        .path = "`<app>/<path>`",
        .old = "The text to change, exactly as it is in the file, once",
        .new = "What it becomes; empty to remove it",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .path = "The file",
        .bytes = "Its size now",
    };
};
