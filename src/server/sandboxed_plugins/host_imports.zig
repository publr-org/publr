//! The host functions a plugin's module may import, each under the name the guest's
//! `extern "env"` declares it with.
const wasm = @import("publr_wasm");
const drawing = @import("drawing.zig");
const drawing_page = @import("drawing_page.zig");
const shaped_call = @import("shaped_call.zig");
const batched = @import("batched.zig");
const host_calls = @import("host_calls.zig");
const granted = @import("granted.zig");
const asks = @import("asks.zig");

pub const imports = [_]wasm.Import{
    .{
        .name = "publr_call_shaped",
        .signature = "(ii)i",
        .function = &shaped_call.publr_call_shaped,
    },
    .{
        .name = "publr_answer",
        .signature = "(iiiii)i",
        .function = &shaped_call.publr_answer,
    },
    .{
        .name = "publr_shaped_take",
        .signature = "(ii)i",
        .function = &shaped_call.publr_shaped_take,
    },
    .{
        .name = "publr_item",
        .signature = "(ii)",
        .function = &batched.publr_item,
    },
    .{
        .name = "publr_emit",
        .signature = "(i)",
        .function = &host_calls.publr_emit,
    },
    .{
        .name = "publr_log",
        .signature = "(ii)",
        .function = &host_calls.publr_log,
    },
    .{
        .name = "publr_undo",
        .signature = "()",
        .function = &host_calls.publr_undo,
    },
    .{
        .name = "publr_fail",
        .signature = "(iiii)",
        .function = &host_calls.publr_fail,
    },
    .{
        .name = "publr_granted",
        .signature = "(ii)i",
        .function = &granted.publr_granted,
    },
    .{
        .name = "publr_grant_domains",
        .signature = "(iii)i",
        .function = &granted.publr_grant_domains,
    },
    .{
        .name = "publr_log_at",
        .signature = "(iii)",
        .function = &host_calls.publr_log_at,
    },
    .{
        .name = "publr_held",
        .signature = "(iii)",
        .function = &host_calls.publr_held,
    },
    .{
        .name = "publr_refuse",
        .signature = "(iiiii)",
        .function = &host_calls.publr_refuse,
    },
    .{
        .name = "publr_problem",
        .signature = "(iiii)",
        .function = &host_calls.publr_problem,
    },
    .{
        .name = "publr_enqueue",
        .signature = "(i)i",
        .function = &host_calls.publr_enqueue,
    },
    .{
        .name = "publr_frame",
        .signature = "(iiii)i",
        .function = &drawing.publr_frame,
    },
    .{
        .name = "publr_draw",
        .signature = "(ii)i",
        .function = &drawing_page.publr_draw,
    },
    .{
        .name = "publr_translate",
        .signature = "(ii)i",
        .function = &drawing.publr_translate,
    },
    .{
        .name = "publr_call_alone",
        .signature = "(ii)i",
        .function = &asks.publr_call_alone,
    },
    .{
        .name = "publr_may",
        .signature = "(iii)i",
        .function = &asks.publr_may,
    },
    .{
        .name = "publr_failure_message",
        .signature = "(i)i",
        .function = &asks.publr_failure_message,
    },
};
