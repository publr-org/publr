//! A removal list: what an agent asked to remove for good, waiting for a person, who reads
//! it, keeps what should stay and removes the rest. Agents never remove; they list.

const std = @import("std");

/// Items on one list, at most.
pub const items_max: u32 = 100;
pub const label_len_max: u32 = 300;
pub const detail_len_max: u32 = 1024;
pub const input_len_max: u32 = 8 << 10;

/// A list waits until its person decides; then it is done.
pub const State = enum {
    waiting,
    done,

    pub fn parse(text: []const u8) ?State {
        return std.meta.stringToEnum(State, text);
    }
};

/// One item: waiting, removed, trashed (moved to the trash instead, restorable), kept (the
/// person left it), failed (the removal refused), or blocked (never removed this way; the
/// person does it by hand).
pub const ItemState = enum {
    waiting,
    removed,
    trashed,
    kept,
    failed,
    blocked,

    pub fn parse(text: []const u8) ?ItemState {
        return std.meta.stringToEnum(ItemState, text);
    }
};

/// What a removal says about itself before it runs: what goes, what goes with it, and why
/// it can never go this way, with how to do it by hand.
pub const Described = struct {
    label: []const u8,
    detail: []const u8 = "",
    blocked: []const u8 = "",
};

test "states read back from their names" {
    try std.testing.expectEqual(State.waiting, State.parse("waiting").?);
    try std.testing.expectEqual(ItemState.blocked, ItemState.parse("blocked").?);
    try std.testing.expect(ItemState.parse("gone") == null);
}
