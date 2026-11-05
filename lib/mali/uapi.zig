//! Version-stable Panthor and Panfrost DRM UAPI used by the transport layer.

const std = @import("std");

pub const drm_command_base: u8 = 0x40;

// Linux defines DRM_CLOEXEC and DRM_RDWR as aliases of O_CLOEXEC and O_RDWR.
// These values are passed through drm_prime_handle.flags unchanged.
pub const drm_cloexec: u32 = 0x80000;
pub const drm_rdwr: u32 = 0x2;
pub const drm_prime_export_flags: u32 = drm_cloexec | drm_rdwr;

pub fn drmIowr(comptime nr: u8, comptime T: type) u32 {
    return std.os.linux.IOCTL.IOWR('d', nr, T);
}

test "PRIME export uses DRM flags rather than open flags" {
    try std.testing.expectEqual(@as(u32, 0x80002), drm_prime_export_flags);
}

// include/uapi/drm/panthor_drm.h
pub const PanthorDevQuery = extern struct {
    type: u32,
    size: u32,
    pointer: u64,
};

pub const PanthorGpuInfo = extern struct {
    gpu_id: u32,
    gpu_rev: u32,
    csf_id: u32,
    l2_features: u32,
    tiler_features: u32,
    mem_features: u32,
    mmu_features: u32,
    thread_features: u32,
    max_threads: u32,
    thread_max_workgroup_size: u32,
    thread_max_barrier_size: u32,
    coherency_features: u32,
    texture_features: [4]u32,
    as_present: u32,
    selected_coherency: u32,
    shader_present: u64,
    l2_present: u64,
    tiler_present: u64,
    core_features: u32,
    pad: u32,
    gpu_features: u64,
};

pub const panthor_dev_query_gpu_info: u32 = 0;
pub const panthor_dev_query_csif_info: u32 = 1;
pub const panthor_dev_query_timestamp_info: u32 = 2;
pub const panthor_dev_query_group_priorities_info: u32 = 3;
pub const panthor_dev_query_mmu_info: u32 = 4;
pub const ioctl_panthor_dev_query = drmIowr(drm_command_base + 0, PanthorDevQuery);

pub const PanthorCsifInfo = extern struct {
    csg_slot_count: u32,
    cs_slot_count: u32,
    cs_reg_count: u32,
    scoreboard_slot_count: u32,
    unpreserved_cs_reg_count: u32,
    pad: u32 = 0,
};

pub const PanthorTimestampInfo = extern struct {
    timestamp_frequency: u64,
    current_timestamp: u64,
    timestamp_offset: u64,
    flags: u32 = 0,
    duration_nsec: u32 = 0,
    cycle_count: u64 = 0,
    cpu_timestamp_sec: u64 = 0,
    cpu_timestamp_nsec: u64 = 0,
};

pub const PanthorGroupPrioritiesInfo = extern struct {
    allowed_mask: u8,
    pad: [3]u8 = @splat(0),
};

pub const PanthorMmuInfo = extern struct {
    page_size_bitmap: u64,
};

pub const PanthorVmCreate = extern struct {
    flags: u32 = 0,
    id: u32 = 0,
    user_va_range: u64 = 0,
};

pub const PanthorVmDestroy = extern struct {
    id: u32,
    pad: u32 = 0,
};

pub const PanthorVmGetState = extern struct {
    vm_id: u32,
    state: u32 = 0,
};

pub const PanthorObjArray = extern struct {
    stride: u32,
    count: u32,
    array: u64,

    pub fn init(comptime T: type, values: []const T) PanthorObjArray {
        return .{
            .stride = @sizeOf(T),
            .count = @intCast(values.len),
            .array = if (values.len == 0) 0 else @intFromPtr(values.ptr),
        };
    }

    pub fn empty(comptime T: type) PanthorObjArray {
        return init(T, &.{});
    }
};

pub const PanthorSyncOp = extern struct {
    flags: u32,
    handle: u32,
    timeline_value: u64,
};

pub const PanthorVmBindOp = extern struct {
    flags: u32,
    bo_handle: u32 = 0,
    bo_offset: u64 = 0,
    va: u64,
    size: u64,
    syncs: PanthorObjArray = PanthorObjArray.empty(PanthorSyncOp),
};

pub const PanthorVmBind = extern struct {
    vm_id: u32,
    flags: u32 = 0,
    ops: PanthorObjArray,
};

pub const PanthorBoCreate = extern struct {
    size: u64,
    flags: u32 = 0,
    exclusive_vm_id: u32 = 0,
    handle: u32 = 0,
    pad: u32 = 0,
};

pub const PanthorBoMmapOffset = extern struct {
    handle: u32,
    pad: u32 = 0,
    offset: u64 = 0,
};

pub const PanthorQueueCreate = extern struct {
    priority: u8 = 1,
    pad: [3]u8 = @splat(0),
    ringbuf_size: u32 = 64 * 1024,
};

pub const PanthorGroupCreate = extern struct {
    queues: PanthorObjArray,
    max_compute_cores: u8,
    max_fragment_cores: u8 = 0,
    max_tiler_cores: u8 = 0,
    priority: u8 = 1,
    pad: u32 = 0,
    compute_core_mask: u64,
    fragment_core_mask: u64 = 0,
    tiler_core_mask: u64 = 0,
    vm_id: u32,
    group_handle: u32 = 0,
};

pub const PanthorGroupDestroy = extern struct {
    group_handle: u32,
    pad: u32 = 0,
};

pub const PanthorQueueSubmit = extern struct {
    queue_index: u32,
    stream_size: u32 = 0,
    stream_addr: u64 = 0,
    latest_flush: u32 = 0,
    pad: u32 = 0,
    syncs: PanthorObjArray,
};

pub const PanthorGroupSubmit = extern struct {
    group_handle: u32,
    pad: u32 = 0,
    queue_submits: PanthorObjArray,
};

pub const PanthorGroupGetState = extern struct {
    group_handle: u32,
    state: u32 = 0,
    fatal_queues: u32 = 0,
    pad: u32 = 0,
};

pub const PanthorTilerHeapCreate = extern struct {
    vm_id: u32,
    initial_chunk_count: u32,
    chunk_size: u32,
    max_chunks: u32,
    target_in_flight: u32,
    handle: u32 = 0,
    tiler_heap_ctx_gpu_va: u64 = 0,
    first_heap_chunk_gpu_va: u64 = 0,
};

pub const PanthorTilerHeapDestroy = extern struct {
    handle: u32,
    pad: u32 = 0,
};

pub const PanthorBoSyncOp = extern struct {
    handle: u32,
    type: u32,
    offset: u64,
    size: u64,
};

pub const PanthorBoSync = extern struct {
    ops: PanthorObjArray,
};

pub const panthor_vm_bind_map_noexec: u32 = 1 << 1;
pub const panthor_vm_bind_type_unmap: u32 = 1 << 28;
pub const panthor_sync_op_signal: u32 = 1 << 31;
pub const panthor_sync_op_timeline: u32 = 1;
pub const panthor_group_priority_medium: u8 = 1;
pub const panthor_group_state_timed_out: u32 = 1 << 0;
pub const panthor_group_state_fatal_fault: u32 = 1 << 1;
pub const panthor_group_state_innocent: u32 = 1 << 2;
pub const panthor_bo_write_back: u32 = 1 << 1;
pub const panthor_bo_sync_flush: u32 = 0;
pub const panthor_bo_sync_flush_invalidate: u32 = 1;

pub const ioctl_panthor_vm_create = drmIowr(drm_command_base + 1, PanthorVmCreate);
pub const ioctl_panthor_vm_destroy = drmIowr(drm_command_base + 2, PanthorVmDestroy);
pub const ioctl_panthor_vm_bind = drmIowr(drm_command_base + 3, PanthorVmBind);
pub const ioctl_panthor_vm_get_state = drmIowr(drm_command_base + 4, PanthorVmGetState);
pub const ioctl_panthor_bo_create = drmIowr(drm_command_base + 5, PanthorBoCreate);
pub const ioctl_panthor_bo_mmap_offset = drmIowr(drm_command_base + 6, PanthorBoMmapOffset);
pub const ioctl_panthor_group_create = drmIowr(drm_command_base + 7, PanthorGroupCreate);
pub const ioctl_panthor_group_destroy = drmIowr(drm_command_base + 8, PanthorGroupDestroy);
pub const ioctl_panthor_group_submit = drmIowr(drm_command_base + 9, PanthorGroupSubmit);
pub const ioctl_panthor_group_get_state = drmIowr(drm_command_base + 10, PanthorGroupGetState);
pub const ioctl_panthor_tiler_heap_create = drmIowr(drm_command_base + 11, PanthorTilerHeapCreate);
pub const ioctl_panthor_tiler_heap_destroy = drmIowr(drm_command_base + 12, PanthorTilerHeapDestroy);
pub const ioctl_panthor_bo_sync = drmIowr(drm_command_base + 15, PanthorBoSync);

// Core DRM syncobj UAPI. These ioctl numbers are literal core DRM IDs, not
// driver-command-base offsets.
pub const DrmSyncobjCreate = extern struct {
    handle: u32 = 0,
    flags: u32 = 0,
};

pub const DrmSyncobjDestroy = extern struct {
    handle: u32,
    pad: u32 = 0,
};

pub const DrmSyncobjArray = extern struct {
    handles: u64,
    count_handles: u32,
    pad: u32 = 0,
};

pub const DrmSyncobjWait = extern struct {
    handles: u64,
    timeout_nsec: i64,
    count_handles: u32,
    flags: u32,
    first_signaled: u32 = 0,
    pad: u32 = 0,
    deadline_nsec: u64 = 0,
};

pub const drm_syncobj_create_signaled: u32 = 1 << 0;
pub const drm_syncobj_wait_all: u32 = 1 << 0;
pub const drm_syncobj_wait_for_submit: u32 = 1 << 1;
pub const ioctl_drm_syncobj_create = drmIowr(0xbf, DrmSyncobjCreate);
pub const ioctl_drm_syncobj_destroy = drmIowr(0xc0, DrmSyncobjDestroy);
pub const ioctl_drm_syncobj_wait = drmIowr(0xc3, DrmSyncobjWait);
pub const ioctl_drm_syncobj_signal = drmIowr(0xc5, DrmSyncobjArray);

// include/uapi/drm/panfrost_drm.h
pub const PanfrostGetParam = extern struct {
    param: u32,
    pad: u32 = 0,
    value: u64 = 0,
};

pub const PanfrostParam = enum(u32) {
    gpu_prod_id = 0,
    gpu_revision = 1,
    shader_present = 2,
    tiler_present = 3,
    l2_present = 4,
    stack_present = 5,
    as_present = 6,
    js_present = 7,
    l2_features = 8,
    core_features = 9,
    tiler_features = 10,
    mem_features = 11,
    mmu_features = 12,
    thread_features = 13,
    max_threads = 14,
    thread_max_workgroup_size = 15,
    thread_max_barrier_size = 16,
    coherency_features = 17,
    selected_coherency = 44,
};

pub const ioctl_panfrost_get_param = drmIowr(drm_command_base + 4, PanfrostGetParam);

test "probe ABI layouts and ioctl encodings" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PanthorDevQuery));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(PanthorGpuInfo));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(PanthorCsifInfo));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(PanthorTimestampInfo));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(PanthorGroupPrioritiesInfo));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(PanthorMmuInfo));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PanfrostGetParam));
    try std.testing.expectEqual(@as(u32, 0xc0106440), ioctl_panthor_dev_query);
    try std.testing.expectEqual(@as(u32, 0xc0106444), ioctl_panfrost_get_param);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PanthorVmCreate));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(PanthorVmDestroy));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(PanthorVmGetState));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PanthorObjArray));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PanthorSyncOp));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(PanthorVmBindOp));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(PanthorVmBind));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(PanthorBoCreate));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PanthorBoMmapOffset));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(PanthorQueueCreate));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(PanthorGroupCreate));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(PanthorGroupDestroy));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(PanthorQueueSubmit));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(PanthorGroupSubmit));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PanthorGroupGetState));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(PanthorTilerHeapCreate));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(PanthorTilerHeapDestroy));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(PanthorBoSyncOp));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PanthorBoSync));
    try std.testing.expectEqual(@as(u32, 0xc0106441), ioctl_panthor_vm_create);
    try std.testing.expectEqual(@as(u32, 0xc0086442), ioctl_panthor_vm_destroy);
    try std.testing.expectEqual(@as(u32, 0xc0186443), ioctl_panthor_vm_bind);
    try std.testing.expectEqual(@as(u32, 0xc0086444), ioctl_panthor_vm_get_state);
    try std.testing.expectEqual(@as(u32, 0xc0186445), ioctl_panthor_bo_create);
    try std.testing.expectEqual(@as(u32, 0xc0106446), ioctl_panthor_bo_mmap_offset);
    try std.testing.expectEqual(@as(u32, 0xc0386447), ioctl_panthor_group_create);
    try std.testing.expectEqual(@as(u32, 0xc0086448), ioctl_panthor_group_destroy);
    try std.testing.expectEqual(@as(u32, 0xc0186449), ioctl_panthor_group_submit);
    try std.testing.expectEqual(@as(u32, 0xc010644a), ioctl_panthor_group_get_state);
    try std.testing.expectEqual(@as(u32, 0xc028644b), ioctl_panthor_tiler_heap_create);
    try std.testing.expectEqual(@as(u32, 0xc008644c), ioctl_panthor_tiler_heap_destroy);
    try std.testing.expectEqual(@as(u32, 0xc010644f), ioctl_panthor_bo_sync);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(DrmSyncobjCreate));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(DrmSyncobjWait));
    try std.testing.expectEqual(@as(u32, 0xc00864bf), ioctl_drm_syncobj_create);
    try std.testing.expectEqual(@as(u32, 0xc02864c3), ioctl_drm_syncobj_wait);
}
