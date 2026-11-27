//! Fields plugins add to the rows of a list read, as core keeps them: `publr/extended.zig`.
const public = @import("../publr/extended.zig");

pub const Extended = public.Extended;
pub const Error = public.Error;
pub const fields_max = public.fields_max;
pub const rows_max = public.rows_max;

test {
    @import("std").testing.refAllDecls(public);
}
