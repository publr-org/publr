//! The admin's words in other languages: gettext PO files, plural rules, catalogues.
pub const po = @import("i18n/po.zig");
pub const plural = @import("i18n/plural.zig");
pub const catalog = @import("i18n/catalog.zig");
pub const Catalog = catalog.Catalog;
pub const conflicts = @import("i18n/conflicts.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
