//! A field naming a person's account: `owner: publr.Account`, a `user` field, kept and sent
//! as the account's id. `ctx.caller().account()` is the signed-in person's.
const std = @import("std");
const Kind = @import("../model/contract.zig").Kind;

pub const kind_id = "user";
pub const id_len_max: u32 = 64;

pub const Account = struct {
    /// The account's id, as `user list` shows it.
    id: []const u8,

    /// Written as its id, in JSON and in an operation's shape.
    pub const json_scalar: Kind = .string;
    pub const json_label = "an account's id";
    pub const account_ref = true;
    /// Handed over as it lies; JSON writes its id alone, and reads `{ "id": … }` too.
    pub const publr_form = .lone;

    /// Whether it names the same account as `other`.
    pub fn eql(self: Account, other: Account) bool {
        std.debug.assert(self.id.len > 0);
        std.debug.assert(other.id.len > 0);

        return std.mem.eql(u8, self.id, other.id);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Account {
        const value = try std.json.innerParse(std.json.Value, allocator, source, options);

        return jsonParseFromValue(allocator, value, options) catch error.UnexpectedToken;
    }

    /// The id as text, or `{ "id": ... }` as a reference is sent.
    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Account {
        const id = switch (source) {
            .string => |text| text,
            .object => |object| if (object.get("id")) |found| switch (found) {
                .string => |text| text,
                else => return error.UnexpectedToken,
            } else return error.UnexpectedToken,
            else => return error.UnexpectedToken,
        };

        if (id.len == 0 or id.len > id_len_max) {
            return error.UnexpectedToken;
        }

        return .{
            .id = id,
        };
    }

    pub fn jsonStringify(self: Account, writer: anytype) !void {
        std.debug.assert(self.id.len > 0);

        return writer.write(self.id);
    }
};

/// Whether a field's Zig type is `publr.Account`.
pub fn is_account(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "account_ref");
}

test "an account is kept and read as its id" {
    const Affiliate = struct {
        owner: Account,
        payee: ?Account = null,
    };

    try std.testing.expect(is_account(Account));
    try std.testing.expect(!is_account(Affiliate));

    const read = try std.json.parseFromSlice(
        Affiliate,
        std.testing.allocator,
        "{\"owner\":\"u_1\",\"payee\":{\"id\":\"u_2\"}}",
        .{},
    );
    defer read.deinit();

    try std.testing.expectEqualStrings("u_1", read.value.owner.id);
    try std.testing.expect(!read.value.owner.eql(read.value.payee.?));

    const written = try std.json.Stringify.valueAlloc(std.testing.allocator, read.value, .{});
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings("{\"owner\":\"u_1\",\"payee\":\"u_2\"}", written);

    const refused = std.json.parseFromSlice(Affiliate, std.testing.allocator, "{\"owner\":7}", .{});

    try std.testing.expectError(error.UnexpectedToken, refused);
}
