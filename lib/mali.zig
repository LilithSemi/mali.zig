//! Zero-C-dependency Linux userspace bindings for Arm Mali GPUs.
//!
//! The transport layer supports both DRM drivers used by Mesa's Panfrost
//! stack: `panthor` for CSF GPUs such as the FydeTab Duo's Mali-G610, and
//! `panfrost` for older job-manager GPUs. Panthor additionally exposes VM/BO,
//! syncobj, scheduling-group, tiler-heap, typed CSF encoding, and fenced
//! command-buffer submission through an unprivileged DRM render node.

const std = @import("std");

pub const uapi = @import("mali/uapi.zig");
pub const device = @import("mali/device.zig");
pub const csf = @import("mali/csf.zig");
pub const queue = @import("mali/queue.zig");
pub const session = @import("mali/session.zig");
pub const descriptors = @import("mali/descriptors.zig");
pub const compute = @import("mali/compute.zig");
pub const samples = @import("mali/samples.zig");
pub const graphics = @import("mali/graphics.zig");

pub const Device = device.Device;
pub const Driver = device.Driver;
pub const GpuInfo = device.GpuInfo;
pub const Vm = device.Vm;
pub const Bo = device.Bo;
pub const BoOptions = device.BoOptions;
pub const Group = device.Group;
pub const QueueConfig = device.QueueConfig;
pub const GroupConfig = device.GroupConfig;
pub const QueueSubmission = device.QueueSubmission;
pub const SyncPoint = device.SyncPoint;
pub const TilerHeap = device.TilerHeap;
pub const DriverVersion = device.DriverVersion;
pub const CommandBuffer = queue.CommandBuffer;
pub const Fence = queue.Fence;
pub const Session = session.Session;
pub const Queue = session.Queue;
pub const ComputeKernel = compute.Kernel;
pub const ComputeGrid = compute.Grid;
pub const Image = graphics.Image;
pub const NativeGraphicsPipeline = graphics.NativeGraphicsPipeline;
pub const CsifInfo = device.CsifInfo;
pub const TimestampInfo = device.TimestampInfo;
pub const GroupPrioritiesInfo = device.GroupPrioritiesInfo;
pub const MmuInfo = device.MmuInfo;
pub const Error = device.Error;

test {
    std.testing.refAllDecls(@This());
}
