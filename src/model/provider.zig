//! A provider of a contract, as core keeps it: defined publicly in `publr/model/provider.zig`.
const public = @import("../publr/model/provider.zig");

pub const parts_max = public.parts_max;

pub const Part = public.Part;
pub const Registered = public.Registered;
