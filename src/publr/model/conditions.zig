//! When a field group shows: groups of rules, any group matching, every rule of one.

pub const Operator = enum { equal, not_equal, empty, not_empty, contains };
pub const Rule = struct {
    field: []const u8,
    operator: Operator = .equal,
    value: []const u8 = "",
};
pub const Group = struct {
    rules: []const Rule,
};
pub const Set = []const Group;
