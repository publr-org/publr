//! A sign-on token, defined in `publr/model/sign_on_token.zig`.
const public = @import("../publr/model/sign_on_token.zig");

pub const token_len_max = public.token_len_max;
pub const key_hex_len = public.key_hex_len;
pub const lifetime_ms = public.lifetime_ms;
pub const clock_skew_ms = public.clock_skew_ms;
pub const Claims = public.Claims;
pub const Error = public.Error;
pub const sign = public.sign;
pub const verify = public.verify;
pub const public_key_hex = public.public_key_hex;
pub const key_from_hex = public.key_from_hex;
