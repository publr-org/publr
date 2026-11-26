/// What a hook on every transition of a type hears (`Posts.any_transition`): the record,
/// the transition's name, and the statuses it left and reached.
pub const Transitioned = struct {
    record: []const u8,
    transition: []const u8,
    from: []const u8,
    to: []const u8,
};
