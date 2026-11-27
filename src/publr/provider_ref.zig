//! `publr.ProviderRef(Contract)`: a record's field naming one provider of a contract (the
//! order remembers its payment and delivery method). Stored and sent as the provider's name;
//! a write is refused when it names no provider registered into the contract, unless the
//! record held that name already: a provider removed later stays named, shown as removed.
const std = @import("std");
const contract = @import("contract.zig");
const identity = @import("../model/identity.zig");

const Error = @import("operation.zig").Error;

/// The field kind a `ProviderRef` keeps as.
pub const kind_id = "provider";

pub fn ProviderRef(comptime Contract: type) type {
    comptime {
        if (!contract.is_contract(Contract)) {
            @compileError("`publr.ProviderRef` takes a contract: `publr.contract.define` " ++
                "or another plugin's published one");
        }
    }

    return struct {
        /// The provider's name, as it registered (`bank_transfer`).
        name: []const u8,

        /// Handed over as the name itself.
        pub const publr_form = .inner;
        /// The contract whose providers it names: what the field's kind checks against.
        pub const provider_contract: []const u8 = Contract.contract_name;

        const Self = @This();

        /// The provider it names, when it is registered and switched on; null when it was
        /// removed or switched off. Only the contract's owner calls its parts.
        pub fn provider(self: Self, ctx: anytype) Error!?contract.Provider(Contract) {
            std.debug.assert(self.name.len > 0);

            for (try contract.providers(ctx, Contract, .{})) |found| {
                if (std.mem.eql(u8, found.name(), self.name)) {
                    return found;
                }
            }

            return null;
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!Self {
            const value = try std.json.innerParse(std.json.Value, allocator, source, options);

            return jsonParseFromValue(allocator, value, options) catch error.UnexpectedToken;
        }

        pub fn jsonParseFromValue(
            _: std.mem.Allocator,
            source: std.json.Value,
            _: std.json.ParseOptions,
        ) std.json.ParseFromValueError!Self {
            if (source != .string or !identity.valid_provider(source.string)) {
                return error.UnexpectedToken;
            }

            return .{
                .name = source.string,
            };
        }

        /// The name alone: what a record keeps and a caller sends.
        pub fn jsonStringify(self: Self, writer: anytype) !void {
            std.debug.assert(self.name.len > 0);

            return writer.write(self.name);
        }
    };
}

/// Whether a field's Zig type is a `ProviderRef`.
pub fn is_provider_ref(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "provider_contract");
}

test "a provider reference is kept and read as the provider's name" {
    const Pay = struct {
        pub const In = struct {
            amount: i64,
        };
        pub const Out = struct {
            id: []const u8,
        };
    };
    const Method = contract.define(.{
        .name = "test.method",
        .operations = .{
            .pay = Pay,
        },
    });
    const Order = struct {
        method: ProviderRef(Method),
    };

    try std.testing.expect(is_provider_ref(ProviderRef(Method)));
    try std.testing.expect(!is_provider_ref(Order));
    try std.testing.expectEqualStrings("test.method", ProviderRef(Method).provider_contract);

    const read = try std.json.parseFromSlice(
        Order,
        std.testing.allocator,
        "{\"method\":\"bank_transfer\"}",
        .{},
    );
    defer read.deinit();

    try std.testing.expectEqualStrings("bank_transfer", read.value.method.name);

    const written = try std.json.Stringify.valueAlloc(std.testing.allocator, read.value, .{});
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings("{\"method\":\"bank_transfer\"}", written);

    const refused = std.json.parseFromSlice(Order, std.testing.allocator, "{\"method\":7}", .{});

    try std.testing.expectError(error.UnexpectedToken, refused);
}
