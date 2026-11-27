//! Publr's marketplace from a project: which of its plugins what someone wants needs
//! (`plugin.find`, decided by the marketplace on its side), and installing one with what it
//! requires (`plugin.install`). The catalog is the one `catalog.zig` reads. Both reach
//! another server, so both answer at once and run as core's queued work (`job.zig`).
const operation = @import("../../operation.zig");

pub const Pick = struct {
    name: []const u8,
    label: []const u8 = "",
    summary: []const u8 = "",
    requires: []const []const u8 = &.{},
    /// How sure the marketplace is that it gives the request something it needs, 0 to 1.
    fit: f64 = 0,
};

pub const Find = struct {
    pub const name = "plugin.find";
    pub const description = "Ask Publr's marketplace which plugins what you want needs";
    pub const details =
        \\Administrators only. `request` is what someone wants to build, in their words; the
        \\marketplace (Publr's own, at plugins.publr.app, deciding with its own model) is
        \\asked in the background, and this answers at once with an id: `job answer` reads
        \\`{ plugins }` once it lands, the plugins that give the request something it needs,
        \\best first, leaving out those installed here. Install each with `plugin install`;
        \\build only what none of them gives. With `PUBLR_PLUGIN_CATALOG` naming a folder,
        \\or when the marketplace cannot be asked or does not answer in time, every catalog
        \\plugin that builds something is listed instead, for the caller to choose from.
        \\Fails `CatalogUnreachable` only when the catalog itself cannot be read.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        request: []const u8,
    };
    pub const Out = struct {
        /// What `job.answer` reads: `{ plugins }`.
        asked: []const u8,
    };
    pub const Found = struct {
        plugins: []const Pick,
    };
    pub const example: In = .{
        .request = "A shop with products in sizes, and orders I can manage",
    };
    pub const example_out: Out = .{
        .asked = "6a1f0c2e9b3d4a5f60718293",
    };
    pub const field_docs: operation.Docs(In) = .{
        .request = "What they want to build, in their words",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .asked = "For `job answer`: `{ plugins }`, the plugins that fit, best first, " ++
            "each with what it requires",
    };
};

pub const Install = struct {
    pub const name = "plugin.install";
    pub const description = "Install a plugin from Publr's marketplace, with what it requires";
    pub const details =
        \\Administrators only. Answers at once with an id, `job answer` reading how it went.
        \\In the background, the plugin's built module is fetched from the marketplace and
        \\added, as uploading it does, after every plugin it requires (theirs first), and
        \\each is enabled: low and medium permissions are granted, high ones wait for an
        \\administrator under Settings › Plugins. One installed already is only enabled. All
        \\or none; the answer lists every plugin installed or enabled, in order.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {
        /// What `job.answer` reads: `{ names }`.
        asked: []const u8,
    };
    pub const example: In = .{
        .name = "checkout",
    };
    pub const example_out: Out = .{
        .asked = "6a1f0c2e9b3d4a5f60718293",
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The plugin's name, as `plugin find` answers it",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .asked = "For `job answer`: `{ names }`, every plugin installed or enabled, " ++
            "requirements first",
    };
};
