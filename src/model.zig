//! Pure content rules: no database, no HTTP. Data in, data out.

pub const field_group = @import("model/field_group.zig");
pub const field = @import("model/field.zig");
pub const kinds = @import("model/kinds.zig");
pub const validate = @import("model/validate.zig");
pub const defaults = @import("model/defaults.zig");
pub const normalize = @import("model/normalize.zig");
pub const status = @import("model/status.zig");
pub const convert = @import("model/convert.zig");
pub const evolution = @import("model/evolution.zig");
pub const document = @import("model/document.zig");
pub const content_type = @import("model/content_type.zig");
pub const taxonomy = @import("model/taxonomy.zig");
pub const tree = @import("model/tree.zig");
pub const account = @import("model/account.zig");
pub const app = @import("model/app.zig");
pub const role = @import("model/role.zig");
pub const sign_on_token = @import("model/sign_on_token.zig");
pub const view = @import("model/view.zig");
pub const internal_record = @import("model/internal_record.zig");
pub const contract = @import("model/contract.zig");
pub const plugin_contracts = @import("model/plugin_contracts.zig");
pub const version_range = @import("model/version_range.zig");
pub const currency = @import("model/currency.zig");
pub const money = @import("model/money.zig");
pub const input_rule = @import("model/input_rule.zig");
pub const filter = @import("model/filter.zig");
pub const query = @import("model/query.zig");
pub const permission = @import("model/permission.zig");
pub const sandboxed_plugin = @import("model/sandboxed_plugin.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
