//! Taxonomies in the admin, under Structure: `definitions.zig` over the taxonomy operations.
//! A taxonomy's page is its terms (`terms.zig`, at `<base>/<handle>/terms`); its head is
//! edited on its settings page and its fields on its own.
const std = @import("std");
const definitions = @import("definitions.zig");

pub const Pages = definitions.Pages(.{
    .base = "/admin/structure/taxonomies",
    .title = "Taxonomies",
    .noun = "taxonomy",
    .key = "taxonomy",
    .plural = "taxonomies",
    .operations = @import("../../operations/taxonomy.zig"),
    .is_taxonomy = true,
});

pub const back = "/admin/structure/taxonomies";
pub const list = Pages.list;
pub const new_page = Pages.new_page;
pub const settings_page = Pages.settings_page;
pub const create = Pages.create;
pub const update = Pages.update;
pub const delete = Pages.delete;
pub const load = Pages.load;
pub const problems_of = Pages.problems_of;

test {
    std.testing.refAllDecls(@This());
}
