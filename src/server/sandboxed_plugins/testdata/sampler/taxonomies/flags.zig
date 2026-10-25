//! Flags
//!
//! A staff-only mark on a sample note, such as "Needs review": one at a time, never on
//! the site.

const publr = @import("publr");

pub const taxonomy = publr.taxonomy.define(struct {}, .{
    .name = "flag",
    .single = true,
    .internal = true,
});
