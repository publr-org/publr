//! A filter of the content list as a view keeps it.

/// One filter in force: `status is draft`, `updated within 7d`. An empty value is the
/// filter shown with nothing chosen yet ("any"), which constrains nothing.
pub const Clause = struct {
    key: []const u8,
    operator: []const u8,
    value: []const u8 = "",
};
