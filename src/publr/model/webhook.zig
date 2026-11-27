//! What another server sent to a plugin's webhook, as its list shows it.

pub const Delivery = struct {
    id: i64,
    name: []const u8,
    delivery_id: []const u8,
    received_at: i64,
    sender: []const u8,
    verified: bool,
    result: []const u8,
    problem: []const u8,
    lines: []const u8,
};
