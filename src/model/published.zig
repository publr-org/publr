//! A plugin's published interface, as core reads it: defined publicly in
//! `publr/model/published.zig`.
const public = @import("../publr/model/published.zig");

pub const contracts_max = public.contracts_max;
pub const parts_max = public.parts_max;
pub const name_len_max = public.name_len_max;

pub const Component = public.Component;
pub const Part = public.Part;
pub const Contract = public.Contract;
pub const Interface = public.Interface;

pub const owned_by = public.owned_by;
