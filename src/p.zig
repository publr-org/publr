//! Publr's own library, private: what its binaries (main, the browser build, the scripts),
//! its apps' and published interfaces' generated roots and the installed plugins' guest
//! root import as `p`. Plugins and app middleware import `publr` (`publr.zig`), which
//! forwards the public names of `publr/root.zig` and nothing else.
const builtin = @import("builtin");

pub const version = @import("publr/version.zig").version;
/// The public names, as `publr` forwards them.
pub const publr = @import("publr/root.zig");

pub const lib = @import("lib.zig");
pub const db = lib.db;
pub const http = lib.http;
pub const report = lib.report;
pub const sdk = @import("sdk.zig");
pub const model = @import("model.zig");
pub const store = @import("store.zig");
pub const cli = @import("adapters/cli.zig");
pub const server = @import("server.zig");
pub const registry = @import("server/registry.zig");
pub const plugin = @import("sdk/plugin.zig");
pub const published = sdk.published;

pub const routes = @import("server/routes.zig");
pub const plugin_routes = @import("server/plugin_routes.zig");
pub const plugin_states = @import("server/plugin_states.zig");
pub const plugin_hooks = @import("server/plugin_hooks.zig");
pub const rest = @import("adapters/rest.zig");
pub const admin = @import("adapters/admin.zig");
pub const project = @import("server/project.zig");
pub const split = @import("server/split.zig");
pub const apps = @import("adapters/apps.zig");
pub const template = @import("template.zig");
pub const operations = sdk.operations;

const host = builtin.os.tag != .wasi;

pub const serve = if (host) @import("server/serve.zig") else void;
pub const build = if (host) @import("server/build.zig") else void;
pub const plugin_sdk = if (host) @import("server/plugin_sdk.zig") else void;
pub const plugin_build = if (host) @import("server/plugin_build.zig") else void;
pub const plugin_check = if (host) @import("server/plugin_build/check.zig") else void;
pub const operator = if (host) @import("server/operator.zig") else void;
pub const database = if (host) @import("server/database.zig") else void;
pub const bundle = if (host) @import("server/bundle.zig") else void;
pub const gate_backup = if (host) @import("server/gate/backup.zig") else void;
pub const update = if (host) @import("server/update.zig") else void;
pub const agents = if (host) @import("server/agents.zig") else void;
pub const apps_load = if (host) @import("server/apps_load.zig") else void;
pub const seed = if (host) @import("server/seed.zig") else void;
pub const clone_pack = if (host) @import("server/clone/pack_process.zig") else void;
pub const queue_worker = if (host) @import("server/queue_worker.zig") else void;
/// Queued work's passes: the worker's on a server, after each answer in the browser.
pub const queued_jobs = @import("server/queued_jobs.zig");
pub const agent_script = if (host) @import("server/agent_script.zig") else void;
pub const agent = if (host) @import("server/agent.zig") else void;

test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(http);
}
