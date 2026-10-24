//! Shelves
//!
//! Where a sample note sits: shelves nest, each with a colour.

const publr = @import("publr");

const Shelf = struct {
    /// Colour
    colour: ?[]const u8 = null,
};

pub const taxonomy = publr.taxonomy.define(Shelf, .{
    .name = "shelf",
    .public = true,
    .hierarchical = true,
    .fields = .{
        .colour = .{
            .kind = "color",
        },
    },
});
