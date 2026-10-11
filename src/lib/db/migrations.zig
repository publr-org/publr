const migration = @import("migration.zig");

/// Core's migrations since 0.3.0, oldest first, one per minor or major release:
/// `migrations/<x.y.0>.zig`, and the unreleased one while the next is being written, which
/// the Release workflow names. Each entry is
///
///     .of("publr", "0.4.0", @import("migrations/0.4.0.zig"), @embedFile(...)),
///
/// written over five lines. Released ones never change and are never removed: a database
/// made by any release since 0.3.0 runs the chain from where it is.
/// `zig build migration-draft` starts the next one.
pub const core = [_]migration.Migration{};
