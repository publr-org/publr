//! Core's operations by namespace, each its whole module (`run`, helpers, lists): what
//! Publr's own binaries reach through `p.operations`. Plugins name the public shapes,
//! `publr.operations`.

pub const device = @import("operations/device.zig");
pub const apps = @import("operations/apps.zig");
pub const heartbeat = @import("operations/heartbeat.zig");
pub const money = @import("operations/money.zig");
pub const project = @import("operations/project.zig");
pub const clock = @import("operations/clock.zig");
pub const custom_fields = @import("operations/custom_fields.zig");
pub const user = @import("operations/user.zig");
pub const user_type = @import("operations/user_type.zig");
pub const sign_in = @import("operations/sign_in.zig");
pub const sign_on = @import("operations/sign_on.zig");
pub const identity = @import("operations/identity.zig");
pub const status = @import("operations/status.zig");
pub const flow = @import("operations/flow.zig");
pub const role = @import("operations/role.zig");
pub const operation = @import("operations/operation.zig");
pub const content_type = @import("operations/content_type.zig");
pub const record = @import("operations/record.zig");
pub const taxonomy = @import("operations/taxonomy.zig");
pub const term = @import("operations/term.zig");
pub const media = @import("operations/media.zig");
pub const design = @import("operations/design.zig");
pub const snapshot = @import("operations/snapshot.zig");
pub const view = @import("operations/view.zig");
pub const rail = @import("operations/rail.zig");
pub const ai = @import("operations/ai.zig");
pub const secret = @import("operations/secret.zig");
pub const http = @import("operations/http.zig");
pub const mail = @import("operations/mail.zig");
pub const internal = @import("operations/internal.zig");
pub const request = @import("operations/request.zig");
pub const link = @import("operations/link.zig");
pub const messaging = @import("operations/messaging.zig");
pub const plugin = @import("operations/plugin.zig");
pub const dimensions = @import("operations/dimensions.zig");
pub const ledger = @import("operations/ledger.zig");
