//! The dependency index is `publr_deps`: what every built artifact read, and the queue of
//! changed keys the site rebuilds from. Its tables (`deps_*`) live in the site's database.

const publr_deps = @import("publr_deps");

pub const Index = publr_deps.Index;
pub const Options = publr_deps.Options;
pub const Observer = publr_deps.Observer;
pub const Batch = publr_deps.Batch;
pub const Outcome = publr_deps.Outcome;
pub const Error = publr_deps.Error;

/// Milliseconds of quiet after the last change before a batch is taken: an admin
/// publishing several records in a row gets one plan, and a single publish is on the
/// files within the same breath.
pub const quiet_ms: u32 = 250;
