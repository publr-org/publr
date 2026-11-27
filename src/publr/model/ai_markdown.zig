//! The words of a conversation's step, read from their Markdown: blocks of styled runs.

pub const blocks_max: u32 = 256;
pub const runs_max: u32 = 1024;

pub const Run = struct {
    text: []const u8,
    /// `plain`, `bold`, `italic` or `code`.
    style: []const u8,
};

pub const Block = struct {
    /// `paragraph`, `heading`, `bullet` or `numbered`.
    kind: []const u8,
    /// A numbered item's number; 0 for any other block.
    number: u32 = 0,
    runs: []const Run,
};
