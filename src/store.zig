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
pub const snapshots = @import("store/snapshots.zig");
pub const settings = @import("store/settings.zig");
pub const users = @import("store/users.zig");
pub const user_values = @import("store/user_values.zig");
pub const sessions = @import("store/sessions.zig");
pub const sign_on_tokens = @import("store/sign_on_tokens.zig");
pub const identities = @import("store/identities.zig");
pub const views = @import("store/views.zig");
pub const internal_records = @import("store/internal_records.zig");
pub const internal_record_values = @import("store/internal_record_values.zig");
pub const sandboxed_plugins = @import("store/sandboxed_plugins.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
