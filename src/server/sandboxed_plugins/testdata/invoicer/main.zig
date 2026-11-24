//! Issues invoices as PDF files, for the tests of made files.
//!
//! `issue` makes an invoice's file in pieces, larger than one piece, keeps it as a private
//! file of its own media type and signs a link to it; `download`, the link's operation,
//! answers the file, which core serves to whoever holds the link.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "invoicer",
    .version = "0.1.0",
};

/// Invoice file
///
/// An invoice as the buyer downloads it.
pub const InvoiceFile = struct {
    /// Title
    title: []const u8,
};

pub const Invoices = publr.record.define(InvoiceFile, .{
    .name = "invoicer.invoice",
    .kind = .media,
    .title_field = .title,
});

pub const IssueIn = struct {
    /// The invoice's number
    number: []const u8,
};

pub const IssueOut = struct {
    /// The invoice's file
    file: []const u8,
    /// Its size in bytes
    size: u64,
    /// The link the buyer downloads it from
    link: []const u8,
};

/// Issues an invoice: its PDF made in pieces, kept as a private file, a link signed to it.
///
/// Example:
///   in: { "number": "FK-1" }
///   out: { "file": "0190a1b2c3d40001a1b2c3d4", "size": 360042, "link": "/_links/eyJp.Qm9i" }
pub const Issue = publr.operation.define(IssueIn, IssueOut, .{
    .name = "issue",
    .kind = .write,
    .run = issue,
});

/// How many lines the invoice's body holds: past one piece, so it is written in several.
const body_lines: u32 = 12_000;

fn issue(ctx: *publr.Ctx, in: IssueIn) publr.Error!IssueOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.number.len == 0 or in.number.len > 32) {
        return error.Invalid;
    }

    const filename = try ctx.print("invoice-{s}.pdf", .{in.number});
    var file = ctx.make_file("invoicer.invoice", filename);

    try file.write(try ctx.print("%PDF-1.4\n% Invoice {s}\n", .{in.number}));

    var line: u32 = 0;
    var lines: [64]u8 = undefined;

    // One line at a time: the plugin never holds the file.
    while (line < body_lines) : (line += 1) {
        const text = std.fmt.bufPrint(&lines, "% line {d:0>6} of the invoice\n", .{line}) catch {
            return error.Invalid;
        };

        try file.write(text);
    }

    try file.write("%%EOF\n");

    const made = try file.done();
    const link = try ctx.sign("download", made.id, null);

    return .{
        .file = made.id,
        .size = made.size,
        .link = link.path,
    };
}

pub const DownloadIn = struct {
    /// The file the link was signed for
    subject: []const u8,
};

pub const DownloadOut = struct {
    /// The file core serves
    file: []const u8,
};

/// What a signed link to an invoice opens: its file.
///
/// Example:
///   in: { "subject": "0190a1b2c3d40001a1b2c3d4" }
///   out: { "file": "0190a1b2c3d40001a1b2c3d4" }
pub const Download = publr.operation.define(DownloadIn, DownloadOut, .{
    .name = "download",
    .kind = .read,
    .run = download,
});

fn download(ctx: *publr.Ctx, in: DownloadIn) publr.Error!DownloadOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.subject.len == 0) {
        return error.NotFound;
    }

    return .{
        .file = in.subject,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{Invoices},
    .operations = &.{ Issue, Download },
});
