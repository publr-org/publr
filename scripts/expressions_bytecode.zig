//! The admin views' compiled expressions (`expressions.js`, from `pjsx_gen`) as
//! QuickJS bytecode, so a render loads them instead of compiling them. Run by
//! `zig build` as a host tool:
//!
//!     expressions_bytecode <expressions.js> <expressions.bin>
const std = @import("std");
const vm_module = @import("vm");

const source_bytes_max = 16 << 20;

pub fn main(init: std.process.Init) u8 {
    std.debug.assert(source_bytes_max > 0);

    return run(init) catch |err| {
        std.debug.print("expressions_bytecode: {s}\n", .{@errorName(err)});

        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(arena);

    _ = args.next();

    const source_path = args.next() orelse return usage();
    const out_path = args.next() orelse return usage();
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAlloc(io, source_path, arena, .limited(source_bytes_max));
    var vm = try vm_module.VM.init(arena);
    defer vm.deinit();

    const bytecode = vm.compile(source, "publr:expressions") catch |err| {
        std.debug.print("expressions_bytecode: {s}\n", .{vm.failure});

        return err;
    };

    std.debug.assert(bytecode.len > 0);
    try cwd.writeFile(io, .{
        .sub_path = out_path,
        .data = bytecode,
    });

    return 0;
}

fn usage() u8 {
    std.debug.print("usage: expressions_bytecode <expressions.js> <expressions.bin>\n", .{});

    return 2;
}
