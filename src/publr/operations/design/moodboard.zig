//! An app's moodboard: its cards, each a `moodboard_item` record of the app. Saving sends
//! the whole board; the server makes the records match it.
const operation = @import("../../operation.zig");

/// A card on a moodboard: a note, a link, an image, a color, a font or a Figma frame.
pub const Item = @import("item.zig").Item;

const example_items = [_]Item{.{
    .id = "01a11bef9de700004e7cf7d2",
    .kind = "note",
    .across = 32,
    .down = 32,
    .width = 220,
    .text = "Calm, lots of white space",
    .note = "In the client brief",
}};

pub const Moodboard = struct {
    pub const name = "design.moodboard";
    pub const description = "Read an app's moodboard: every card, with why it is there";
    pub const details =
        \\Signed-in editors and administrators. The cards of the app's board in the order
        \\they were added, each with its record's id, its kind (`note`, `link`, `image`,
        \\`color`, `font`, `figma`), its place and size, and what its kind shows. What an
        \\agent reads to learn what the site should look like.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        app: []const u8,
    };
    pub const Out = struct {
        items: []const Item,
    };
    pub const example: In = .{
        .app = "www",
    };
    // An app whose board has no cards yet.
    pub const example_out: Out = .{
        .items = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{
        .app = "The app's `.name`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .items = "Every card: its `id`, `kind`, place and size, and what its kind shows",
    };
};

pub const SaveMoodboard = struct {
    pub const name = "design.save_moodboard";
    pub const description = "Save an app's whole moodboard: its records made to match";
    pub const details =
        \\Signed-in editors and administrators. `items` is the whole board, in order. A card
        \\whose `id` is one of the app's moodboard records saves into it (only when it
        \\changed); any other card, a new one with the editor's own id, becomes a new
        \\record; a record the board no longer holds moves to the trash. Answers the board
        \\with every card's record id, for the editor to keep. Up to 200 cards; a kind it
        \\does not know, or a place that is not a number, is refused.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        app: []const u8,
        items: []const Item = &.{},
    };
    pub const Out = struct {
        items: []const Item,
    };
    pub const example: In = .{
        .app = "www",
        .items = &example_items,
    };
    pub const example_out: Out = .{
        .items = &example_items,
    };
    pub const field_docs: operation.Docs(In) = .{
        .app = "The app's `.name`",
        .items = "Every card on the board, as `design moodboard` answers them",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .items = "The board as saved: the same cards, each `id` its record's",
    };
};
