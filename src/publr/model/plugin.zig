//! How a plugin is loaded: `native`, built into this binary, or `sandboxed`, installed and run
//! in the sandbox.
pub const Mode = enum { native, sandboxed };
