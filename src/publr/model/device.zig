//! What a device's sign-in keeps to: the name it shows its person, how long a request waits
//! and how often the device asks again.

/// The most characters a device's name has.
pub const name_len_max: u32 = 80;
/// How long a request waits for its person before it lapses.
pub const request_lifetime_ms: i64 = 10 * 60 * 1000;
/// How often a device asks whether its person decided.
pub const poll_interval_s: u32 = 3;
