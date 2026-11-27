//! A value a message names (`{project}`), filled in where it is said.

pub const Said = struct {
    name: []const u8,
    value: []const u8,
};
