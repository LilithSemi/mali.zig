//! Read-only Mali DRM probe. No root access or C libraries are required.

const std = @import("std");
const mali = @import("mali");

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var forced: ?[]const u8 = null;
    var args = init.minimal.args.iterate();
    _ = args.next();
    if (args.next()) |arg| forced = arg;

    var dev = if (forced) |path|
        mali.Device.openNode(init.gpa, path) catch |err| {
            try out.print("RESULT: SKIP could-not-open {s} ({s})\n", .{ path, @errorName(err) });
            return;
        }
    else
        mali.Device.open(init.gpa) catch |err| {
            var n: u32 = 128;
            while (n < 192) : (n += 1) {
                var name_buf: [32]u8 = undefined;
                if (mali.Device.renderNodeDriver(init.gpa, n, &name_buf)) |driver|
                    try out.print("  renderD{d}: driver={s}\n", .{ n, driver });
            }
            if (err == error.OpenFailed)
                try out.writeAll("RESULT: SKIP mali-device-not-accessible (check render-group permissions)\n")
            else
                try out.writeAll("RESULT: SKIP no-mali-device (expected kernel driver 'panthor' or 'panfrost')\n");
            return;
        };
    defer dev.deinit();

    const info = dev.query() catch |err| {
        try out.print("driver: {s}\n", .{@tagName(dev.driver)});
        try out.print("RESULT: FAIL gpu-info-query ({s})\n", .{@errorName(err)});
        return;
    };

    if (dev.render_minor) |minor| try out.print("device: /dev/dri/renderD{d}\n", .{minor});
    try out.print("driver: {s}\n", .{@tagName(info.driver)});
    try out.print("driver_version: {d}.{d}.{d}\n", .{ dev.version.major, dev.version.minor, dev.version.patch });
    try out.print("gpu_name: {s}\n", .{info.name});
    try out.print("gpu_id: 0x{x:0>8}\n", .{info.gpu_id});
    try out.print("gpu_revision: 0x{x}\n", .{info.gpu_revision});
    try out.print("architecture: v{d}.{d}\n", .{ info.architecture_major, info.architecture_minor });
    try out.print("product_major: {d}\n", .{info.product_major});
    try out.print("shader_present: 0x{x}\n", .{info.shader_present});
    try out.print("shader_core_count: {d}\n", .{info.shader_core_count});
    try out.print("l2_present: 0x{x}\n", .{info.l2_present});
    try out.print("l2_count: {d}\n", .{info.l2_count});
    try out.print("tiler_present: 0x{x}\n", .{info.tiler_present});
    try out.print("address_spaces: {d} (mask 0x{x})\n", .{ info.address_space_count, info.as_present });
    try out.print("mmu_va_bits: {d}\n", .{info.mmu_va_bits});
    try out.print("max_threads: {d}\n", .{info.max_threads});
    try out.print("max_workgroup_size: {d}\n", .{info.max_workgroup_size});
    try out.print("selected_coherency: {d}\n", .{info.selected_coherency});
    if (info.csf_id) |csf_id| try out.print("csf_id: 0x{x:0>8}\n", .{csf_id});

    if (info.driver != .panthor) {
        try out.writeAll("roundtrip: SKIP Panthor memory UAPI not available on panfrost\n");
        try out.writeAll("RESULT: OK\n");
        return;
    }

    if (dev.queryCsif()) |csif| {
        try out.print("csif: csg_slots={d} cs_slots={d} registers={d} scoreboards={d} unpreserved_registers={d}\n", .{
            csif.csg_slot_count,
            csif.cs_slot_count,
            csif.cs_reg_count,
            csif.scoreboard_slot_count,
            csif.unpreserved_cs_reg_count,
        });
    } else |err| {
        try out.print("csif: SKIP ({s}, ioctl=0x{x} errno={d})\n", .{ @errorName(err), dev.last_request, dev.last_errno });
    }
    if (dev.queryTimestamp()) |timestamp| {
        try out.print("timestamp: frequency={d} current={d} offset={d}\n", .{
            timestamp.timestamp_frequency,
            timestamp.current_timestamp,
            timestamp.timestamp_offset,
        });
    } else |err| {
        try out.print("timestamp: SKIP ({s}, ioctl=0x{x} errno={d})\n", .{ @errorName(err), dev.last_request, dev.last_errno });
    }
    if (dev.queryGroupPriorities()) |priorities| {
        try out.print("group_priorities_mask: 0x{x}\n", .{priorities.allowed_mask});
    } else |err| {
        try out.print("group_priorities: SKIP ({s}, ioctl=0x{x} errno={d})\n", .{ @errorName(err), dev.last_request, dev.last_errno });
    }
    if (dev.queryMmu()) |mmu| {
        try out.print("mmu_page_size_bitmap: 0x{x}\n", .{mmu.page_size_bitmap});
    } else |err| {
        try out.print("mmu_info: SKIP ({s}, ioctl=0x{x} errno={d})\n", .{ @errorName(err), dev.last_request, dev.last_errno });
    }

    const vm = dev.vmCreate() catch |err| {
        try printFailure(out, &dev, "vm-create", err);
        return;
    };
    defer dev.vmDestroy(vm);
    try out.print("vm_id: {d}\n", .{vm.id});
    try out.print("vm_user_va_range: 0x{x}\n", .{vm.user_va_range});
    const vm_state = dev.vmState(vm) catch |err| {
        try printFailure(out, &dev, "vm-get-state", err);
        return;
    };
    try out.print("vm_state: {d}\n", .{vm_state});

    const heap = dev.tilerHeapCreate(vm, 1, 128 * 1024, 4, 1) catch |err| {
        try printFailure(out, &dev, "tiler-heap-create", err);
        return;
    };
    defer dev.tilerHeapDestroy(heap);
    try out.print("tiler_heap_handle: {d}\n", .{heap.handle});
    try out.print("tiler_heap_context_gpu_va: 0x{x}\n", .{heap.context_gpu_va});
    try out.print("tiler_heap_first_chunk_gpu_va: 0x{x}\n", .{heap.first_chunk_gpu_va});

    const bo_size: u64 = 16 * 1024;
    const gpu_va: u64 = 0x10000;
    const bo = dev.allocBoWithOptions(vm, bo_size, gpu_va, .{ .exportable = true }) catch |err| {
        try printFailure(out, &dev, "bo-alloc-map-bind", err);
        return;
    };
    defer dev.freeBo(vm, bo);
    try out.print("bo_handle: {d}\n", .{bo.handle});
    try out.print("bo_gpu_va: 0x{x}\n", .{bo.gpu_va});
    try out.print("bo_size: {d}\n", .{bo.size});

    for (bo.cpu, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    for (bo.cpu, 0..) |byte, i| {
        const expected: u8 = @truncate(i *% 31 +% 7);
        if (byte != expected) {
            try out.print("roundtrip: MISMATCH at byte {d}\n", .{i});
            try out.writeAll("RESULT: FAIL roundtrip\n");
            return;
        }
    }
    try out.print("roundtrip: {d} bytes CPU write+readback OK\n", .{bo.cpu.len});

    // PRIME export is useful for compositor interop but is independent of the
    // command submission tests below. Keep probing after a failure so one run
    // captures the complete hardware bring-up picture.
    var dma_buf_export_failed = false;
    if (dev.boExportDmaBuf(bo)) |prime_fd| {
        defer _ = std.os.linux.close(prime_fd);
        try out.print("dma_buf_export: GEM handle {d} -> fd {d} OK\n", .{ bo.handle, prime_fd });
    } else |err| {
        dma_buf_export_failed = true;
        try out.print("dma_buf_export: FAIL ({s})\n", .{@errorName(err)});
        if (err == error.IoctlFailed)
            try out.print("ioctl_request: 0x{x} errno: {d}\n", .{ dev.last_request, dev.last_errno });
        try out.writeAll("dma_buf_export: continuing remaining diagnostics\n");
    }

    const cpu_sync = dev.syncobjCreate(false) catch |err| {
        try printFailure(out, &dev, "syncobj-create", err);
        return;
    };
    defer dev.syncobjDestroy(cpu_sync);
    dev.syncobjSignal(cpu_sync) catch |err| {
        try printFailure(out, &dev, "syncobj-signal", err);
        return;
    };
    var cpu_syncs = [_]u32{cpu_sync};
    dev.syncobjWait(&cpu_syncs, 1_000_000_000) catch |err| {
        try printFailure(out, &dev, "syncobj-wait", err);
        return;
    };
    try out.writeAll("syncobj_roundtrip: create+signal+wait OK\n");

    const group = dev.groupCreate(vm, info) catch |err| {
        try printFailure(out, &dev, "group-create", err);
        return;
    };
    defer dev.groupDestroy(group);
    try out.print("group_handle: {d}\n", .{group.handle});
    try out.print("group_queue_count: {d}\n", .{group.queue_count});
    const before = dev.groupState(group) catch |err| {
        try printFailure(out, &dev, "group-get-state", err);
        return;
    };
    try out.print("group_state_before_submit: 0x{x} fatal_queues=0x{x}\n", .{ before.state, before.fatal_queues });

    const submit_sync = dev.syncobjCreate(false) catch |err| {
        try printFailure(out, &dev, "submit-syncobj-create", err);
        return;
    };
    defer dev.syncobjDestroy(submit_sync);
    dev.groupSubmitSync(group, submit_sync) catch |err| {
        try printFailure(out, &dev, "group-submit-sync", err);
        return;
    };
    var submit_syncs = [_]u32{submit_sync};
    dev.syncobjWait(&submit_syncs, 1_000_000_000) catch |err| {
        try printFailure(out, &dev, "group-submit-wait", err);
        return;
    };
    const after = dev.groupState(group) catch |err| {
        try printFailure(out, &dev, "group-get-state-after-submit", err);
        return;
    };
    try out.print("group_state_after_submit: 0x{x} fatal_queues=0x{x}\n", .{ after.state, after.fatal_queues });
    try out.writeAll("queue_submit: zero-stream synchronization submit OK\n");

    var command = mali.CommandBuffer.create(&dev, vm, 16 * 1024, 0x20000) catch |err| {
        try printFailure(out, &dev, "command-buffer-create", err);
        return;
    };
    defer command.deinit(&dev, vm);
    command.encoder.nop(0, 0) catch |err| {
        try out.print("command-encode: FAIL ({s})\nRESULT: FAIL command-encode\n", .{@errorName(err)});
        return;
    };
    command.submitAndWait(&dev, group, 0, &.{}, 1_000_000_000) catch |err| {
        try printFailure(out, &dev, "command-submit-nop", err);
        return;
    };
    try out.writeAll("command_stream: executable NOP submit+fence OK\n");

    // Exercise the same ownership/configuration path Prism will use: a fresh
    // VM, three queues, production-sized tiler heap, executable shader BO,
    // v10 descriptors, and one real RUN_COMPUTE dispatch.
    var prism_session = mali.Session.open(init.gpa) catch |err| {
        try printFailure(out, &dev, "prism-session-open", err);
        return;
    };
    defer prism_session.deinit();
    try out.print("prism_session_page_size: {d}\n", .{prism_session.page_size});
    try out.print("prism_session_queue_count: {d}\n", .{prism_session.group.queue_count});
    var kernel = mali.ComputeKernel.create(&prism_session, &mali.compute.noop_shader, 1, 0) catch |err| {
        try printFailure(out, &prism_session.dev, "compute-kernel-create", err);
        return;
    };
    defer kernel.deinit(&prism_session);
    mali.compute.dispatchNoResources(&prism_session, kernel, .{}, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "compute-dispatch-noop", err);
        return;
    };
    try out.writeAll("compute_dispatch: Valhall NOP.end shader completed OK\n");

    const compute_target = prism_session.allocBo(4096, .{}) catch |err| {
        try printFailure(out, &prism_session.dev, "compute-target-create", err);
        return;
    };
    defer prism_session.freeBo(compute_target);
    @memset(compute_target.cpu[0..4], 0);
    var store_kernel = mali.ComputeKernel.create(&prism_session, &mali.compute.write_constant_shader, 3, 0) catch |err| {
        try printFailure(out, &prism_session.dev, "compute-store-kernel-create", err);
        return;
    };
    defer store_kernel.deinit(&prism_session);
    mali.compute.dispatchWriteConstant(&prism_session, store_kernel, compute_target, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "compute-store-dispatch", err);
        return;
    };
    const stored = std.mem.readInt(u32, compute_target.cpu[0..4], .little);
    try out.print("compute_store_value: 0x{x:0>8}\n", .{stored});
    if (stored != 0x11223344) {
        try out.writeAll("RESULT: FAIL compute-store-readback\n");
        return;
    }
    try out.writeAll("compute_store: FAU pointer + GPU store + CPU readback OK\n");

    var clear_target = mali.Image.create(&prism_session, 64, 64) catch |err| {
        try printFailure(out, &prism_session.dev, "fragment-clear-target-create", err);
        return;
    };
    defer clear_target.deinit(&prism_session);
    @memset(clear_target.bo.cpu, 0x5a);
    const clear_color = [4]u8{ 0x25, 0x7a, 0xd3, 0xff };
    mali.graphics.clearRgba8(&prism_session, clear_target, clear_color, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "fragment-clear-dispatch", err);
        return;
    };
    var clear_mismatch: ?usize = null;
    const pixels = clear_target.pixels();
    for (0..clear_target.height) |y| {
        for (0..clear_target.width) |x| {
            const offset = y * clear_target.row_stride + x * 4;
            if (!std.mem.eql(u8, pixels[offset..][0..4], &clear_color)) {
                clear_mismatch = offset;
                break;
            }
        }
        if (clear_mismatch != null) break;
    }
    if (clear_mismatch) |offset| {
        try out.print("fragment_clear_mismatch: offset={d} expected={x:0>2}{x:0>2}{x:0>2}{x:0>2} actual={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
            offset,
            clear_color[0],
            clear_color[1],
            clear_color[2],
            clear_color[3],
            pixels[offset],
            pixels[offset + 1],
            pixels[offset + 2],
            pixels[offset + 3],
        });
        try out.writeAll("RESULT: FAIL fragment-clear-readback\n");
        return;
    }
    try out.print("fragment_clear: 64x64 linear RGBA8 RUN_FRAGMENT clear/readback OK (rgba={x:0>2}{x:0>2}{x:0>2}{x:0>2})\n", .{
        clear_color[0], clear_color[1], clear_color[2], clear_color[3],
    });

    const center_offset = (@as(usize, clear_target.height) / 2) * clear_target.row_stride +
        (@as(usize, clear_target.width) / 2) * 4;
    @memset(clear_target.bo.cpu, 0x5a);
    var fullscreen_diagnostics = mali.graphics.FullscreenDiagnostics{};
    if (mali.graphics.drawFullscreenDiagnosticRgba8(
        &prism_session,
        clear_target,
        .{ 0, 1, 0, 1 },
        &fullscreen_diagnostics,
        1_000_000_000,
    )) |_| {
        const fullscreen_actual = clear_target.pixels()[center_offset..][0..4];
        try out.print(
            "graphics_fullscreen_center: expected=00ff00ff actual={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n",
            .{ fullscreen_actual[0], fullscreen_actual[1], fullscreen_actual[2], fullscreen_actual[3] },
        );
    } else |err| {
        try printSessionFailure(out, &prism_session, "graphics-fullscreen-diagnostic", err);
        try out.writeAll("RESULT: FAIL graphics-fullscreen-diagnostic\n");
        return;
    }
    try out.print(
        "graphics_fullscreen_cs_error_status: pre=0x{x:0>16} post=0x{x:0>16} fragment=0x{x:0>16}\n",
        .{
            fullscreen_diagnostics.pre_run_error_status,
            fullscreen_diagnostics.post_run_error_status,
            fullscreen_diagnostics.fragment_error_status,
        },
    );

    @memset(clear_target.bo.cpu, 0x5a);
    var draw_diagnostics = mali.graphics.DrawDiagnostics{};
    mali.graphics.drawProbeTriangleDiagnosticRgba8(&prism_session, clear_target, &draw_diagnostics, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "graphics-probe-triangle", err);
        return;
    };
    const expected_red = [4]u8{ 0xff, 0x00, 0x00, 0xff };
    if (!std.mem.eql(u8, clear_target.pixels()[center_offset..][0..4], &expected_red)) {
        const actual = clear_target.pixels()[center_offset..][0..4];
        try out.print("graphics_probe_center: expected=ff0000ff actual={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
            actual[0], actual[1], actual[2], actual[3],
        });
        if (prism_session.dev.groupState(prism_session.group)) |state|
            try out.print("graphics_probe_group_state: 0x{x} fatal_queues=0x{x}\n", .{ state.state, state.fatal_queues })
        else |state_err|
            try out.print("graphics_probe_group_state: unavailable ({s})\n", .{@errorName(state_err)});
        try printWords(out, "tiler_context_before", &draw_diagnostics.tiler_context_before);
        try printWords(out, "tiler_context_after_tiling", &draw_diagnostics.tiler_context_after_tiling);
        try printWords(out, "tiler_context_after_fragment", &draw_diagnostics.tiler_context_after_fragment);
        try printWords(out, "heap_descriptor_before", &draw_diagnostics.heap_descriptor_before);
        try printWords(out, "heap_descriptor_after_tiling", &draw_diagnostics.heap_descriptor_after_tiling);
        try printWords(out, "heap_descriptor_after_fragment", &draw_diagnostics.heap_descriptor_after_fragment);
        try out.print("geometry_nonzero_bytes_after_tiling: {d}\n", .{draw_diagnostics.geometry_nonzero_bytes_after_tiling});
        if (draw_diagnostics.geometry_first_nonzero_offset) |offset|
            try out.print("geometry_first_nonzero_offset: {d}\n", .{offset})
        else
            try out.writeAll("geometry_first_nonzero_offset: none\n");
        try printWords(out, "idvs_registers_after_run", &draw_diagnostics.idvs_registers_after_run);
        try out.print("pre_idvs_cs_error_status: 0x{x:0>16}\n", .{draw_diagnostics.pre_idvs_error_status});
        try out.print("tiling_cs_error_status: 0x{x:0>16}\n", .{draw_diagnostics.tiling_error_status});
        try out.print("fragment_cs_error_status: 0x{x:0>16}\n", .{draw_diagnostics.fragment_error_status});
        try out.writeAll("RESULT: FAIL graphics-probe-center-readback\n");
        return;
    }
    try out.writeAll("graphics_probe: PanVK-compiled vertex+fragment shaders drew red triangle over blue clear; center pixel OK\n");

    const mixed_color = [4]f32{ 0.25, 0.5, 0.75, 1.0 };
    mali.graphics.drawConstantColorTriangleRgba8(&prism_session, clear_target, mixed_color, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "graphics-constant-color-triangle", err);
        return;
    };
    const expected_mixed = [4]u8{ 0x40, 0x80, 0xbf, 0xff };
    if (!std.mem.eql(u8, clear_target.pixels()[center_offset..][0..4], &expected_mixed)) {
        const actual = clear_target.pixels()[center_offset..][0..4];
        try out.print("graphics_constant_center: expected=4080bfff actual={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
            actual[0], actual[1], actual[2], actual[3],
        });
        try out.writeAll("RESULT: FAIL graphics-constant-center-readback\n");
        return;
    }
    try out.writeAll("graphics_constant: generated Valhall immediate shader drew rgba=(0.25,0.5,0.75,1.0); center pixel OK\n");

    const vertex_color = [3]f32{ 0.25, 0.75, 0.5 };
    mali.graphics.drawVertexColorTriangleRgba8(&prism_session, clear_target, vertex_color, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "graphics-vertex-color-triangle", err);
        return;
    };
    const expected_vertex_color = [4]u8{ 0x40, 0xbf, 0x80, 0xff };
    if (!std.mem.eql(u8, clear_target.pixels()[center_offset..][0..4], &expected_vertex_color)) {
        const actual = clear_target.pixels()[center_offset..][0..4];
        try out.print("graphics_vertex_color_center: expected=40bf80ff actual={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
            actual[0], actual[1], actual[2], actual[3],
        });
        try out.writeAll("RESULT: FAIL graphics-vertex-color-center-readback\n");
        return;
    }
    try out.writeAll("graphics_vertex_color: secondary IDVS shader carried vec3 attribute through interpolated varying; center pixel OK\n");

    mali.graphics.drawBatchedHalvesRgba8(&prism_session, clear_target, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "graphics-multi-draw", err);
        return;
    };
    const sample_y = (@as(usize, clear_target.height) / 2) * clear_target.row_stride;
    const left_offset = sample_y + (@as(usize, clear_target.width) / 4) * 4;
    const right_offset = sample_y + (@as(usize, clear_target.width) * 3 / 4) * 4;
    const left_actual = clear_target.pixels()[left_offset..][0..4];
    const right_actual = clear_target.pixels()[right_offset..][0..4];
    const expected_green = [4]u8{ 0, 0xff, 0, 0xff };
    if (!std.mem.eql(u8, left_actual, &expected_red) or !std.mem.eql(u8, right_actual, &expected_green)) {
        try out.print("graphics_multi_draw_samples: left={x:0>2}{x:0>2}{x:0>2}{x:0>2} right={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
            left_actual[0],  left_actual[1],  left_actual[2],  left_actual[3],
            right_actual[0], right_actual[1], right_actual[2], right_actual[3],
        });
        try out.writeAll("RESULT: FAIL graphics-multi-draw-readback\n");
        return;
    }
    try out.writeAll("graphics_multi_draw: two pipelines and vertex buffers shared one tiler/fragment pass; left/right samples OK\n");

    mali.graphics.drawAlphaBlendTriangleRgba8(&prism_session, clear_target, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "graphics-alpha-blend", err);
        return;
    };
    const expected_blend = [4]u8{ 0x80, 0, 0x80, 0xff };
    const blend_actual = clear_target.pixels()[center_offset..][0..4];
    // Fixed-function UNORM conversion may resolve an exact half to either
    // adjacent 8-bit value (127 or 128), depending on the hardware rounding
    // path. Both represent the requested 0.5 blend within one quantization
    // step.
    if (!pixelNear(blend_actual, expected_blend, 1)) {
        try out.print("graphics_alpha_blend_center: expected=800080ff actual={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
            blend_actual[0], blend_actual[1], blend_actual[2], blend_actual[3],
        });
        try out.writeAll("RESULT: FAIL graphics-alpha-blend-readback\n");
        return;
    }
    try out.writeAll("graphics_alpha_blend: fixed-function 50%-red over blue produced opaque purple; center pixel OK\n");

    mali.graphics.drawScissorProbeRgba8(&prism_session, clear_target, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "graphics-scissor", err);
        return;
    };
    const corner_actual = clear_target.pixels()[0..4];
    const scissor_center = clear_target.pixels()[center_offset..][0..4];
    if (!std.mem.eql(u8, corner_actual, &expected_red) or !std.mem.eql(u8, scissor_center, &expected_green)) {
        try out.print("graphics_scissor_samples: corner={x:0>2}{x:0>2}{x:0>2}{x:0>2} center={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
            corner_actual[0],  corner_actual[1],  corner_actual[2],  corner_actual[3],
            scissor_center[0], scissor_center[1], scissor_center[2], scissor_center[3],
        });
        try out.writeAll("RESULT: FAIL graphics-scissor-readback\n");
        return;
    }
    try out.writeAll("graphics_scissor: per-draw tile bounding box clipped green to center over red clear; samples OK\n");

    const rrect_corner_offset = @as(usize, 9) * clear_target.row_stride + 9 * 4;
    mali.graphics.drawRoundedRectangleProbeRgba8(&prism_session, clear_target, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "graphics-rounded-rectangle", err);
        return;
    };
    const rrect_center = clear_target.pixels()[center_offset..][0..4];
    const rrect_corner = clear_target.pixels()[rrect_corner_offset..][0..4];
    const expected_blue = [4]u8{ 0, 0, 0xff, 0xff };
    var rrect_failed = false;
    if (!pixelNear(rrect_center, expected_blend, 1) or !std.mem.eql(u8, rrect_corner, &expected_blue)) {
        try out.print("graphics_rrect_samples: center={x:0>2}{x:0>2}{x:0>2}{x:0>2} rounded_corner={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
            rrect_center[0], rrect_center[1], rrect_center[2], rrect_center[3],
            rrect_corner[0], rrect_corner[1], rrect_corner[2], rrect_corner[3],
        });
        try out.writeAll("graphics_rounded_rectangle: FAIL readback (continuing texture diagnostics)\n");
        rrect_failed = true;
    } else {
        try out.writeAll("graphics_rounded_rectangle: PhantomUI 48-byte vertex ABI + three varying slots + SDF fragment shader readback OK\n");
    }

    mali.graphics.drawTextAndImageProbeRgba8(&prism_session, clear_target, 1_000_000_000) catch |err| {
        try printSessionFailure(out, &prism_session, "graphics-texture-sampling", err);
        return;
    };
    const text_sample = clear_target.pixels()[left_offset..][0..4];
    const image_sample = clear_target.pixels()[right_offset..][0..4];
    const expected_text = [4]u8{ 0x80, 0, 0x7f, 0xff };
    const expected_image = [4]u8{ 0x10, 0x60, 0x9f, 0xff };
    if (!pixelNear(text_sample, expected_text, 2) or !pixelNear(image_sample, expected_image, 2)) {
        try out.print("graphics_texture_samples: text={x:0>2}{x:0>2}{x:0>2}{x:0>2} image={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
            text_sample[0],  text_sample[1],  text_sample[2],  text_sample[3],
            image_sample[0], image_sample[1], image_sample[2], image_sample[3],
        });
        try out.writeAll("RESULT: FAIL graphics-texture-sampling-readback\n");
        return;
    }
    try out.writeAll("graphics_textures: PhantomUI text-alpha and RGBA image shaders sampled one linear texture; left/right readbacks OK\n");
    if (rrect_failed)
        try out.writeAll("RESULT: FAIL graphics-rounded-rectangle-readback\n")
    else if (dma_buf_export_failed)
        try out.writeAll("RESULT: FAIL dma-buf-export (remaining diagnostics completed)\n")
    else
        try out.writeAll("RESULT: OK\n");
}

fn pixelNear(actual: []const u8, expected: [4]u8, tolerance: u8) bool {
    if (actual.len < 4) return false;
    for (expected, 0..) |value, i| {
        const delta = if (actual[i] > value) actual[i] - value else value - actual[i];
        if (delta > tolerance) return false;
    }
    return true;
}

fn printWords(out: *std.Io.Writer, label: []const u8, words: []const u32) !void {
    try out.print("{s}:", .{label});
    for (words) |word| try out.print(" {x:0>8}", .{word});
    try out.writeByte('\n');
}

fn printFailure(out: *std.Io.Writer, dev: *const mali.Device, operation: []const u8, err: anyerror) !void {
    try out.print("{s}: FAIL ({s})\n", .{ operation, @errorName(err) });
    if (err == error.IoctlFailed)
        try out.print("ioctl_request: 0x{x} errno: {d}\n", .{ dev.last_request, dev.last_errno });
    try out.print("RESULT: FAIL {s}\n", .{operation});
}

fn printSessionFailure(out: *std.Io.Writer, session: *mali.Session, operation: []const u8, err: anyerror) !void {
    if (session.dev.groupState(session.group)) |state| {
        try out.print("group_state_on_failure: 0x{x} fatal_queues=0x{x}\n", .{ state.state, state.fatal_queues });
    } else |state_err| {
        try out.print("group_state_on_failure: unavailable ({s})\n", .{@errorName(state_err)});
    }
    try printFailure(out, &session.dev, operation, err);
}
