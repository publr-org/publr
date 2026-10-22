//! Secrets a plugin names but never holds: API keys and the like. What a name may be, how a
//! stored value is sealed with the project's key (and opened again), and how a request a
//! plugin wrote with `{secret:NAME}` in it is filled in at the last moment.

const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

pub const name_len_max: u32 = 64;
pub const value_len_max: u32 = 8 << 10;
pub const key_bytes: u32 = Aead.key_length;
/// The key as `PUBLR_SECRET_KEY` and `secret.key` hold it: hex.
pub const key_hex_len: u32 = key_bytes * 2;
/// A sealed value: its nonce, the encrypted bytes, the tag.
pub const sealed_overhead: u32 = Aead.nonce_length + Aead.tag_length;

pub const Key = [key_bytes]u8;

/// `STOCKS_API_KEY`: capitals, digits and underscores, starting with a letter, as an
/// environment variable of the same name would be.
pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);
    std.debug.assert(name.len <= 64 << 10);

    if (name.len == 0 or name.len > name_len_max or !std.ascii.isUpper(name[0])) {
        return false;
    }

    for (name) |byte| {
        if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte) and byte != '_') {
            return false;
        }
    }

    return true;
}

/// A key written as hex; null unless it is exactly 64 hex digits.
pub fn key_of(hex: []const u8) ?Key {
    std.debug.assert(key_hex_len == 64);
    std.debug.assert(hex.len <= 64 << 10);

    const trimmed = std.mem.trim(u8, hex, " \t\r\n");

    if (trimmed.len != key_hex_len) {
        return null;
    }

    var key: Key = undefined;
    _ = std.fmt.hexToBytes(&key, trimmed) catch return null;

    return key;
}

/// `value` sealed under `key`, bound to `name`: a sealed value moved to another name does
/// not open.
pub fn seal(
    arena: std.mem.Allocator,
    io: std.Io,
    key: Key,
    name: []const u8,
    value: []const u8,
) ![]const u8 {
    std.debug.assert(valid_name(name));
    std.debug.assert(value.len <= value_len_max);

    const sealed = try arena.alloc(u8, sealed_overhead + value.len);
    const nonce = sealed[0..Aead.nonce_length];
    const cipher = sealed[Aead.nonce_length..][0..value.len];
    const tag = sealed[Aead.nonce_length + value.len ..][0..Aead.tag_length];

    io.random(nonce);
    Aead.encrypt(cipher, tag, value, name, nonce.*, key);

    return sealed;
}

/// The value `sealed` holds; null when it was sealed under another key or name, or was
/// changed.
pub fn open(
    arena: std.mem.Allocator,
    key: Key,
    name: []const u8,
    sealed: []const u8,
) !?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(sealed_overhead > 0);

    if (sealed.len < sealed_overhead) {
        return null;
    }

    const length = sealed.len - sealed_overhead;
    const value = try arena.alloc(u8, length);
    const nonce = sealed[0..Aead.nonce_length];
    const cipher = sealed[Aead.nonce_length..][0..length];
    const tag = sealed[Aead.nonce_length + length ..][0..Aead.tag_length];

    Aead.decrypt(value, cipher, tag.*, name, nonce.*, key) catch return null;

    return value;
}

/// A secret a plugin declares in its `.secrets`: its name, the label people see (its
/// `///`'s first line) and where to find it (the rest).
pub const Declared = struct {
    name: []const u8,
    label: []const u8,
    help: []const u8 = "",
};

/// How many secrets one plugin may declare.
pub const declared_max: u32 = 32;

/// The declared secret called `name`; null when the plugin did not declare it.
pub fn declared_find(declared: []const Declared, name: []const u8) ?*const Declared {
    std.debug.assert(declared.len <= declared_max);
    std.debug.assert(name.len > 0);

    for (declared) |*each| {
        if (std.mem.eql(u8, each.name, name)) {
            return each;
        }
    }

    return null;
}

/// The first name in `written` that `declared` lacks: what a plugin's code writes as
/// `{secret:NAME}` without declaring it. Null when every one is declared.
pub fn undeclared(declared: []const []const u8, written: []const []const u8) ?[]const u8 {
    std.debug.assert(declared.len <= declared_max);
    std.debug.assert(written.len <= 1024);

    for (written) |name| {
        if (!contains(declared, name)) {
            return name;
        }
    }

    return null;
}

/// Every valid name written as `{secret:NAME}` in `text`, appended to `out` unless there
/// already: what a plugin's string literals ask for. Malformed markers are left to the
/// request that sends them.
pub fn written_in(
    arena: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    std.debug.assert(out.items.len <= 1024);

    var rest = text;

    while (std.mem.indexOf(u8, rest, marker_open)) |at| {
        const after = rest[at + marker_open.len ..];
        const end = std.mem.indexOfScalar(u8, after, '}') orelse return;
        const name = after[0..end];

        if (valid_name(name) and !contains(out.items, name) and out.items.len < 1024) {
            try out.append(arena, try arena.dupe(u8, name));
        }

        rest = after[end..];
    }
}

pub const marker_open = "{secret:";

/// The names `text` asks for with `{secret:NAME}`, in order, each once; at most `list.len`.
pub fn names_in(text: []const u8, list: [][]const u8) ![]const []const u8 {
    std.debug.assert(list.len > 0);
    std.debug.assert(text.len <= std.math.maxInt(u32));

    var count: u32 = 0;
    var rest = text;

    while (std.mem.indexOf(u8, rest, marker_open)) |at| {
        const after = rest[at + marker_open.len ..];
        const end = std.mem.indexOfScalar(u8, after, '}') orelse return error.Unclosed;
        const name = after[0..end];

        if (!valid_name(name)) {
            return error.InvalidName;
        }

        if (!contains(list[0..count], name)) {
            if (count == list.len) {
                return error.TooMany;
            }

            list[count] = name;
            count += 1;
        }

        rest = after[end + 1 ..];
    }

    return list[0..count];
}

/// `text` with every `{secret:NAME}` replaced by `values[i]` for `names[i]`.
pub fn fill(
    arena: std.mem.Allocator,
    text: []const u8,
    names: []const []const u8,
    values: []const []const u8,
) ![]const u8 {
    std.debug.assert(names.len == values.len);
    std.debug.assert(text.len <= std.math.maxInt(u32));

    var filled: std.ArrayList(u8) = .empty;
    var rest = text;

    while (std.mem.indexOf(u8, rest, marker_open)) |at| {
        const after = rest[at + marker_open.len ..];
        const end = std.mem.indexOfScalar(u8, after, '}') orelse return error.Unclosed;
        const index = index_of(names, after[0..end]) orelse return error.Unknown;

        try filled.appendSlice(arena, rest[0..at]);
        try filled.appendSlice(arena, values[index]);
        rest = after[end + 1 ..];
    }

    try filled.appendSlice(arena, rest);

    return filled.items;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    return index_of(list, name) != null;
}

fn index_of(list: []const []const u8, name: []const u8) ?u32 {
    std.debug.assert(name.len <= 64 << 10);
    std.debug.assert(list.len <= 1024);

    for (list, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) {
            return @intCast(index);
        }
    }

    return null;
}

test "a secret's name is an environment variable's" {
    try std.testing.expect(valid_name("STOCKS_API_KEY"));
    try std.testing.expect(valid_name("A1"));
    try std.testing.expect(!valid_name("stocks"));
    try std.testing.expect(!valid_name("1KEY"));
    try std.testing.expect(!valid_name(""));
    try std.testing.expect(!valid_name("A" ** 65));
}

test "a sealed value opens under its key and name only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const key = key_of("00" ** 32).?;
    const other = key_of("11" ** 32).?;
    const sealed = try seal(arena, std.testing.io, key, "API_KEY", "sk-123");

    try std.testing.expect(std.mem.indexOf(u8, sealed, "sk-123") == null);
    try std.testing.expectEqualStrings("sk-123", (try open(arena, key, "API_KEY", sealed)).?);
    try std.testing.expect(try open(arena, other, "API_KEY", sealed) == null);
    try std.testing.expect(try open(arena, key, "OTHER_KEY", sealed) == null);
    try std.testing.expect(try open(arena, key, "API_KEY", sealed[0..4]) == null);
    try std.testing.expect(key_of("zz") == null);
}

test "a request's secrets are named, then filled in" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var storage: [4][]const u8 = undefined;
    const text = "Bearer {secret:API_KEY}; x={secret:OTHER} y={secret:API_KEY}";
    const names = try names_in(text, &storage);

    try std.testing.expectEqual(@as(usize, 2), names.len);
    const filled = try fill(arena, text, names, &.{ "k", "o" });
    try std.testing.expectEqualStrings("Bearer k; x=o y=k", filled);
    try std.testing.expectError(error.Unclosed, names_in("{secret:API_KEY", &storage));
    try std.testing.expectError(error.InvalidName, names_in("{secret:api}", &storage));
    try std.testing.expectEqual(@as(usize, 0), (try names_in("plain", &storage)).len);
}

test "the secrets a plugin writes, and which it did not declare" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var written: std.ArrayList([]const u8) = .empty;

    try written_in(arena, "Bearer {secret:API_KEY} {secret:api} {secret:API_KEY}", &written);
    try written_in(arena, "x={secret:OTHER}&y={secret:", &written);
    try std.testing.expectEqual(@as(usize, 2), written.items.len);
    try std.testing.expectEqualStrings("OTHER", written.items[1]);
    try std.testing.expect(undeclared(&.{ "API_KEY", "OTHER" }, written.items) == null);
    try std.testing.expectEqualStrings("OTHER", undeclared(&.{"API_KEY"}, written.items).?);

    const declared = [_]Declared{.{
        .name = "API_KEY",
        .label = "Supplier API key",
    }};

    const found = declared_find(&declared, "API_KEY").?;

    try std.testing.expectEqualStrings("Supplier API key", found.label);
    try std.testing.expect(declared_find(&declared, "OTHER") == null);
}
