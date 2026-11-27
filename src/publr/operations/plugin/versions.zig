//! Moving a plugin between its versions, and reading it: each by its name alone, answering
//! the plugin as its page shows it.
const operation = @import("../../operation.zig");
const detail = @import("detail.zig");

const Detail = detail.Detail;

/// An operation on one plugin by name, answering it as its page shows it.
pub fn ByName(
    comptime operation_name: []const u8,
    comptime text: []const u8,
    comptime explained: []const u8,
    comptime operation_kind: operation.Kind,
    comptime documented: Detail,
) type {
    return struct {
        pub const name = operation_name;
        pub const description = text;
        pub const details = explained;
        pub const kind = operation_kind;
        pub const In = struct {
            name: []const u8,
        };
        pub const Out = Detail;
        pub const example: In = .{
            .name = "greeter",
        };
        pub const example_out: Out = documented;
        pub const field_docs: operation.Docs(In) = .{
            .name = "The plugin's name",
        };
    };
}

pub const Get = ByName(
    "plugin.get",
    "Read a plugin: every request and where it stands, its versions",
    "Each request (a permission, a hook, a raised limit, an added status) with the " ++
        "plugin's reason, its tier, and whether it is granted, pending, denied, or " ++
        "unavailable (nothing installed provides it); for a disabled plugin, as enabling " ++
        "it would leave it. With a " ++
        "next version waiting, its version and requests; with a previous one, its version.",
    .read,
    detail.example_detail,
);

pub const Update = ByName(
    "plugin.update",
    "Apply a plugin's next version, keeping the current one to roll back to",
    "Everything the next version asks for that something installed provides is granted: " ++
        "an administrator reviews it before. Not found when no next version waits.",
    .write,
    detail.example_updated,
);

pub const CancelUpdate = ByName(
    "plugin.cancel_update",
    "Drop a plugin's next version; the current one stays",
    "Not found when no next version waits.",
    .write,
    detail.example_cancelled,
);

pub const Rollback = ByName(
    "plugin.rollback",
    "Go back to the version the last update replaced",
    "The version it leaves becomes the previous one, so a roll back can be undone the " ++
        "same way. Not found when there is no previous version.",
    .write,
    detail.example_rolled_back,
);
