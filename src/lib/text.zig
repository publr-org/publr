//! Slugs and their suffixes, defined in `publr/slug.zig`.
const public = @import("../publr/slug.zig");

pub const slug_len_max = public.slug_len_max;
pub const attempts_max = public.attempts_max;
pub const slugify = public.slugify;
pub const with_suffix = public.with_suffix;
