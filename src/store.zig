//! The tables, one module each: SQL and nothing else. The record and term domains share
//! one generic store per table shape (`definitions`, `documents`, `document_values`);
//! `records`/`terms`, `values`/`term_values` and `content_types`/`taxonomies` name the
//! tables.

pub const field_groups = @import("store/field_groups.zig");
pub const tables = @import("store/tables.zig");
pub const definitions = @import("store/definitions.zig");
pub const documents = @import("store/documents.zig");
pub const document_values = @import("store/document_values.zig");
pub const content_types = @import("store/content_types.zig");
pub const records = @import("store/records.zig");
pub const values = @import("store/values.zig");
pub const taxonomies = @import("store/taxonomies.zig");
pub const terms = @import("store/terms.zig");
pub const term_values = @import("store/term_values.zig");
pub const record_terms = @import("store/record_terms.zig");
pub const media = @import("store/media.zig");
pub const snapshots = @import("store/snapshots.zig");
pub const settings = @import("store/settings.zig");
pub const users = @import("store/users.zig");
pub const user_roles = @import("store/user_roles.zig");
pub const roles = @import("store/roles.zig");
pub const role_grants = @import("store/role_grants.zig");
pub const role_declarations = @import("store/role_declarations.zig");
pub const user_values = @import("store/user_values.zig");
pub const sessions = @import("store/sessions.zig");
pub const sign_on_tokens = @import("store/sign_on_tokens.zig");
pub const devices = @import("store/devices.zig");
pub const device_requests = @import("store/device_requests.zig");
pub const identities = @import("store/identities.zig");
pub const views = @import("store/views.zig");
pub const rail_pins = @import("store/rail_pins.zig");
pub const shared_rail_pins = @import("store/shared_rail_pins.zig");
pub const shared_views = @import("store/shared_views.zig");
pub const default_views = @import("store/default_views.zig");
pub const ai_conversations = @import("store/ai_conversations.zig");
pub const ai_steps = @import("store/ai_steps.zig");
pub const ai_pictures = @import("store/ai_pictures.zig");
pub const ai_browsers = @import("store/ai_browsers.zig");
pub const ai_activity = @import("store/ai_activity.zig");
pub const removals = @import("store/removals.zig");
pub const trash_copy = @import("store/trash_copy.zig");
pub const stored_rows = @import("store/stored_rows.zig");
pub const trash = @import("store/trash.zig");
pub const health_kept = @import("store/health_kept.zig");
pub const secrets = @import("store/secrets.zig");
pub const internal_records = @import("store/internal_records.zig");
pub const activity = @import("store/activity.zig");
pub const errors = @import("store/errors.zig");
pub const plugin_log = @import("store/plugin_log.zig");
pub const job_queue = @import("store/job_queue.zig");
pub const scheduled_transitions = @import("store/scheduled_transitions.zig");
pub const internal_record_values = @import("store/internal_record_values.zig");
pub const sandboxed_plugins = @import("store/sandboxed_plugins.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
