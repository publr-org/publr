//! Dedicated schema authoring over the shared definition engine.
const definitions = @import("definitions.zig");
const Pages = definitions.Pages(.{
    .base = "/admin/structure/settings",
    .title = "Settings",
    .noun = "settings section",
    .key = "type",
    .plural = "types",
    .operations = @import("../../operations/content_type.zig"),
    .is_taxonomy = false,
    .fixed_kind = .settings,
});
pub const list = Pages.list;
pub const new_page = Pages.new_page;
pub const settings_page = Pages.settings_page;
pub const create = Pages.create;
pub const update = Pages.update;
pub const delete = Pages.delete;
