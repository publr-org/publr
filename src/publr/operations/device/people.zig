//! The person's side of devices: the request they approve or deny, and the devices that
//! act for them, which they list and revoke. Every operation here is open (any account,
//! whatever its roles, manages its own devices) and checks who calls itself.
const operation = @import("../../operation.zig");

pub const example_code = "WXZB-CDFG";
pub const example_device_id = "56a0794f6b1c67062563204a";

pub const Request = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.request";
    pub const description = "What a waiting device asks for, by the code its person has";
    pub const details =
        \\Any signed-in account; what the approve page shows. Not found once the request
        \\was decided or lapsed.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const In = struct {
        code: []const u8,
    };
    pub const Out = struct {
        name: []const u8,
        scope: []const u8,
        expires_at: i64,
        returns_to: []const u8 = "",
    };
    pub const example: In = .{
        .code = example_code,
    };
    pub const example_out: Out = .{
        .name = "An agent on Ada's laptop",
        .scope = "production",
        .expires_at = 1792232000000,
        .returns_to = "",
    };
    pub const field_docs: operation.Docs(In) = .{
        .code = "The user code, `WXZB-CDFG`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .name = "What the device calls itself",
        .scope = "What it asks to do",
        .expires_at = "When the request lapses, Unix milliseconds",
        .returns_to = "An MCP client's return address, where the person goes once they " ++
            "decide; empty for a device's own request",
    };
};

pub const Approve = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.approve";
    pub const description = "Let a waiting device act for your account";
    pub const details =
        \\A signed-in account approves for itself, never through a device. `scope` may be
        \\what the device asked or less. The device collects its token on its next poll.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        code: []const u8,
        scope: []const u8,
    };
    pub const Out = struct {
        approved: bool,
        sent_back: []const u8 = "",
    };
    pub const example: In = .{
        .code = example_code,
        .scope = "production",
    };
    pub const example_out: Out = .{
        .approved = true,
        .sent_back = "",
    };
    pub const field_docs: operation.Docs(In) = .{
        .code = "The user code, `WXZB-CDFG`",
        .scope = "`read`, `write`, `production` or `publish`, no more than it asked",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .approved = "Always true",
        .sent_back = "For an MCP client, where to send the person: its return address " ++
            "with the code it trades for its token; empty for a device's own request",
    };
};

pub const Deny = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.deny";
    pub const description = "Refuse a waiting device";
    pub const details = "A signed-in account. The device learns it on its next poll.";
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        code: []const u8,
    };
    pub const Out = struct {
        denied: bool,
        sent_back: []const u8 = "",
    };
    pub const example: In = .{
        .code = example_code,
    };
    pub const example_out: Out = .{
        .denied = true,
        .sent_back = "",
    };
    pub const field_docs: operation.Docs(In) = .{
        .code = "The user code, `WXZB-CDFG`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .denied = "Always true",
        .sent_back = "For an MCP client, its return address saying it was refused; empty " ++
            "for a device's own request",
    };
};

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    scope: []const u8,
    user_id: []const u8,
    /// The account's email, so an administrator sees whose it is.
    email: []const u8,
    created_at: i64,
    last_used_at: i64,
    /// The device making this call.
    current: bool,
};

pub const List = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.list";
    pub const description = "The devices acting for your account, or for everyone's";
    pub const details =
        \\Any signed-in account sees its own; a device sees its account's. `all` lists every
        \\account's, for administrators. Revoked devices are not listed. Newest first.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const In = struct {
        all: bool = false,
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        devices: []const Item,
        total: u32 = 0,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .devices = &.{.{
            .id = example_device_id,
            .name = "An agent on Ada's laptop",
            .scope = "production",
            .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
            .email = "ada@example.com",
            .created_at = 1792232000000,
            .last_used_at = 1792235600000,
            .current = false,
        }},
    };
    pub const field_docs: operation.Docs(In) = .{
        .all = "Every account's devices (administrators only)",
        .limit = "How many at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first: the next page's start",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .devices = "A page of them, newest first",
        .total = "How many there are in all",
    };
};

pub const Revoke = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.revoke";
    pub const description = "Stop a device acting for its account";
    pub const details =
        \\A signed-in account revokes its own devices, an administrator anyone's; a device
        \\may revoke only itself (`publr logout`). It stops working at once.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        revoked: bool,
    };
    pub const example: In = .{
        .id = example_device_id,
    };
    pub const example_out: Out = .{
        .revoked = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The device, as `device list` shows it",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .revoked = "Always true",
    };
};

pub const Update = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.update";
    pub const description = "Change what a device may do";
    pub const details =
        \\A signed-in account changes its own devices, an administrator anyone's. A device
        \\never changes itself. It counts from the device's next call.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        id: []const u8,
        scope: []const u8,
    };
    pub const Out = struct {
        scope: []const u8,
    };
    pub const example: In = .{
        .id = example_device_id,
        .scope = "write",
    };
    pub const example_out: Out = .{
        .scope = "write",
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The device, as `device list` shows it",
        .scope = "`read`, `write`, `production` or `publish`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .scope = "What it may do from now on",
    };
};
