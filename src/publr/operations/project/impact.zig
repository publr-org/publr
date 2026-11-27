//! What the dependency index holds for a record or its type: the keys a change to it
//! raises, and every built artifact (a page, a fragment) that recorded reading one of them.
const operation = @import("../../operation.zig");

pub const Artifact = struct {
    /// The artifact as the build names it: the app and a page's URL, or the app and
    /// `/_islands/<key>` (`www:/posts/hello`).
    name: []const u8,
    /// The keys it recorded, among those the change raises, in the order raised.
    keys: []const []const u8,
};

/// Artifacts one change may reach; past it the index itself refuses the batch.
pub const artifacts_max: u32 = 4096;

pub const Impact = struct {
    pub const name = "project.impact";
    pub const description =
        "What a change to a record rebuilds: the keys it raises and the built artifacts " ++
        "that recorded them";
    pub const details =
        \\Reads the dependency index the apps' builds fill: every rendered page and fragment
        \\records the record ids and types it read, and a change to a record raises
        \\`record:<id>`, `type:<handle>` and `records`. This lists those keys for the record
        \\(or, without an id, for a record of the type that does not exist yet) and every
        \\artifact that recorded any of them: exactly what the next quiet moment rebuilds.
        \\Signed-in users may call it. Nothing is written. An empty list, as in the example,
        \\means no build has recorded the keys yet (a fresh install, or apps that render
        \\live); after `publr build` a post's page answers, for instance, `{ "name":
        \\"www:/posts/hello", "keys": ["record:<id>", "type:post", "records"] }`. The
        \\artifacts a page at a time, in the order of their names: `next` continues it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        type: []const u8,
        id: ?[]const u8 = null,
        after: []const u8 = "",
    };
    pub const Out = struct {
        keys: []const []const u8,
        artifacts: []const Artifact,
        next: []const u8 = "",
    };
    pub const example: In = .{
        .type = "post",
        .id = "a1b2c3d4e5f60718293a4b5c",
    };
    pub const example_out: Out = .{
        .keys = &.{ "record:a1b2c3d4e5f60718293a4b5c", "type:post", "records" },
        .artifacts = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "The record type's handle",
        .id = "The record; omitted for one that does not exist yet",
        .after = "The page after this artifact: the `next` the last page answered",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .keys = "The keys a change raises, in the order they are raised",
        .artifacts = "Every artifact that recorded one of the keys, once, by name, with the " ++
            "keys it recorded",
        .next = "The next page's `after`; empty after the last",
    };
};
