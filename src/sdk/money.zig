//! `publr.Money`: whole minor units by currency, as a `money` field holds it and as
//! operations pass it. A plain list of amounts, one per currency, so it is handed between
//! plugins and Publr as it lies; JSON, where Publr keeps or sends it, is `{ "PLN": 12300 }`.
const std = @import("std");

pub const Error = error{OutOfMemory};

pub const Money = struct {
    /// One amount per currency, in the order they were put.
    amounts: []const Amount = &.{},

    pub const Amount = struct {
        /// The currency's code: `PLN`.
        currency: []const u8,
        /// Whole minor units: 12300 is 123.00.
        minor: i64,
    };

    /// Laid out as its list, each amount keyed by its currency.
    pub const publr_form = .keyed;
    pub const json_object = true;
    pub const json_label = "money: minor units by currency, `{ \"PLN\": 12300 }`";
    pub const money_amounts = true;

    /// `minor` units of one currency.
    pub fn of(arena: std.mem.Allocator, currency: []const u8, minor: i64) Error!Money {
        const amounts = try arena.alloc(Amount, 1);

        std.debug.assert(currency.len > 0);

        amounts[0] = .{
            .currency = currency,
            .minor = minor,
        };

        return .{
            .amounts = amounts,
        };
    }

    /// The amount in `currency`; null when it holds none in it.
    pub fn get(money: Money, currency: []const u8) ?i64 {
        std.debug.assert(money.amounts.len <= std.math.maxInt(u32));

        for (money.amounts) |amount| {
            if (std.mem.eql(u8, amount.currency, currency)) {
                return amount.minor;
            }
        }

        return null;
    }

    /// The amount in `currency`, 0 when it holds none in it.
    pub fn in(money: Money, currency: []const u8) i64 {
        return money.get(currency) orelse 0;
    }

    /// How many currencies it holds an amount in.
    pub fn count(money: Money) u32 {
        std.debug.assert(money.amounts.len <= std.math.maxInt(u32));

        return @intCast(money.amounts.len);
    }

    /// Its one amount, when it holds exactly one currency.
    pub fn single(money: Money) ?Amount {
        return if (money.amounts.len == 1) money.amounts[0] else null;
    }

    /// Sets the amount in `currency`, in a list of its own: what it was made from is left
    /// as it was.
    pub fn put(
        money: *Money,
        arena: std.mem.Allocator,
        currency: []const u8,
        minor: i64,
    ) Error!void {
        std.debug.assert(currency.len > 0);

        for (money.amounts, 0..) |amount, index| {
            if (std.mem.eql(u8, amount.currency, currency)) {
                const copied = try arena.dupe(Amount, money.amounts);

                copied[index].minor = minor;
                money.amounts = copied;

                return;
            }
        }

        const grown = try arena.alloc(Amount, money.amounts.len + 1);

        @memcpy(grown[0..money.amounts.len], money.amounts);
        grown[money.amounts.len] = .{
            .currency = currency,
            .minor = minor,
        };
        money.amounts = grown;
    }

    /// Adds `minor` to the amount in `currency`.
    pub fn add(
        money: *Money,
        arena: std.mem.Allocator,
        currency: []const u8,
        minor: i64,
    ) Error!void {
        std.debug.assert(currency.len > 0);

        return money.put(arena, currency, money.in(currency) + minor);
    }

    pub fn jsonStringify(money: Money, writer: anytype) !void {
        std.debug.assert(money.amounts.len <= std.math.maxInt(u32));

        try writer.beginObject();

        for (money.amounts) |amount| {
            try writer.objectField(amount.currency);
            try writer.write(amount.minor);
        }

        try writer.endObject();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Money {
        const value = try std.json.innerParse(std.json.Value, allocator, source, options);

        return jsonParseFromValue(allocator, value, options) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Money {
        _ = options;

        if (source != .object) {
            return error.UnexpectedToken;
        }

        const amounts = try allocator.alloc(Amount, source.object.count());

        for (source.object.keys(), source.object.values(), amounts) |currency, held, *amount| {
            if (held != .integer) {
                return error.UnexpectedToken;
            }

            amount.* = .{
                .currency = currency,
                .minor = held.integer,
            };
        }

        return .{
            .amounts = amounts,
        };
    }
};

/// Whether a field's Zig type is `publr.Money`.
pub fn is_money(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "money_amounts");
}

test "money holds an amount per currency and reads and writes `{ \"PLN\": 12300 }`" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var money = try Money.of(arena, "PLN", 12300);
    const first = money;

    try money.add(arena, "PLN", 700);
    try money.put(arena, "EUR", 5);

    try std.testing.expectEqual(@as(?i64, 13000), money.get("PLN"));
    try std.testing.expectEqual(@as(i64, 0), money.in("USD"));
    try std.testing.expectEqual(@as(u32, 2), money.count());
    try std.testing.expect(money.single() == null and first.single().?.minor == 12300);

    const text = try std.json.Stringify.valueAlloc(arena, money, .{});

    try std.testing.expectEqualStrings("{\"PLN\":13000,\"EUR\":5}", text);

    const back = try std.json.parseFromSliceLeaky(Money, arena, text, .{});

    try std.testing.expectEqual(@as(?i64, 5), back.get("EUR"));
    try std.testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSliceLeaky(Money, arena, "{\"PLN\":\"a\"}", .{}),
    );
}
