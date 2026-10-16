//! `GET /api/agent/<code>`: the setup an agent's computer runs, `curl -fsSL <it> | sh`. It
//! installs the publr command (Publr's installer, carried in this binary), signs the
//! computer in to this site with the sign-in the Overview offered (`device offer`, the code
//! in the address), and gives the agent in the folder it runs in the Publr skill. Nothing in
//! it is secret beyond the code, which works once, for ten minutes.
const std = @import("std");
const http = @import("../lib/http.zig");
const device = @import("../model/device.zig");
const Project = @import("project.zig").Project;

pub const route = "/api/agent/:code";
pub const prefix = "/api/agent/";
const installer = @embedFile("installer");
const address_len_max: u32 = 512;

pub fn handle(
    request: *http.Request,
    response: *http.Response,
    ctx: *http.Context,
) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(installer.len > 0);

    const code = request.param("code") orelse "";
    const site = try address_of(request, ctx.arena, Project.of(ctx));

    if (!device.valid_offer_code(code) or !shell_safe(site)) {
        return response.text(.not_found, "echo 'publr: this command is not one Publr made; " ++
            "copy it again from your site' >&2; exit 1\n");
    }

    const script = try std.fmt.allocPrint(ctx.arena, template, .{
        site,
        site,
        code,
        installer,
    });

    try response.set_header("Cache-Control", "no-store");
    try response.text(.ok, script);
}

/// The site's address: the one it serves at (`--url`), else the one asked.
fn address_of(
    request: *http.Request,
    arena: std.mem.Allocator,
    project: *const Project,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(address_len_max > 0);

    if (project.site_origin.len > 0) {
        return project.site_origin;
    }

    const host = request.header("host") orelse "localhost";
    const forwarded = request.header("x-forwarded-proto") orelse "http";
    const scheme = if (std.mem.eql(u8, forwarded, "https")) "https" else "http";

    return std.fmt.allocPrint(arena, "{s}://{s}", .{ scheme, host });
}

/// Whether an address can go into the script as it is: what addresses are made of, nothing
/// a shell reads as more than a word.
fn shell_safe(address: []const u8) bool {
    std.debug.assert(address_len_max > 0);

    if (address.len == 0 or address.len > address_len_max) {
        return false;
    }

    for (address) |char| {
        const plain = std.ascii.isAlphanumeric(char) or
            std.mem.indexOfScalar(u8, ":/.-_[]", char) != null;

        if (!plain) {
            return false;
        }
    }

    return true;
}

const template =
    \\#!/bin/sh
    \\# Publr for your agent: the publr command, this computer signed in to {s},
    \\# and the Publr skill in this folder.
    \\set -eu
    \\site='{s}'
    \\code='{s}'
    \\bin_dir="${{PUBLR_BIN_DIR:-$HOME/.local/bin}}"
    \\
    \\(
    \\{s}
    \\)
    \\
    \\if ! "$bin_dir/publr" login "$site" --claim "$code"; then
    \\    echo "publr: this command was used already or is older than ten minutes;" >&2
    \\    echo "       copy a new one from your site's Overview" >&2
    \\    exit 1
    \\fi
    \\"$bin_dir/publr" skill install
    \\echo
    \\echo "Done. Start your agent in $(pwd) and ask: it builds with the publr command."
    \\
;

test "only addresses and codes go into the script" {
    try std.testing.expect(shell_safe("https://ada.publr.app"));
    try std.testing.expect(shell_safe("http://ada.publr.localhost:8095"));
    try std.testing.expect(!shell_safe("https://a.app'; rm -rf ~"));
    try std.testing.expect(!shell_safe("https://a.app$(x)"));
    try std.testing.expect(!shell_safe(""));
    try std.testing.expect(device.valid_offer_code("k7q2xm4pw9tz3hbd"));
    try std.testing.expect(!device.valid_offer_code("k7q2xm4pw9tz3hb'"));
    try std.testing.expect(!device.valid_offer_code("short"));
}
