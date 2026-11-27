//! An app's types handed on, when the app is renamed.
const operation = @import("../../operation.zig");

pub const MoveApp = struct {
    pub const name = "project.move_app";
    pub const description = "Hand every type of one app to another, after renaming it";
    pub const details =
        \\An app is known by its `.name`, so renaming it in `app.zon` leaves its content
        \\types and taxonomies under the old name: this moves them to the new one, or with
        \\`to` empty makes them Global. Types shared with the old name are shared with the
        \\new one, and the app's design records (templates, parts, patterns, moodboard
        \\cards) follow. No record changes. Administrators only: it is the project's.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        from: []const u8,
        to: []const u8 = "",
    };
    pub const Out = struct {
        moved: u32,
    };
    pub const example: In = .{
        .from = "www",
        .to = "site",
    };
    pub const example_out: Out = .{
        .moved = 6,
    };
    pub const field_docs: operation.Docs(In) = .{
        .from = "The app's old `.name`",
        .to = "Its new `.name`; empty to make its types Global",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .moved = "How many content types and taxonomies changed",
    };
};
