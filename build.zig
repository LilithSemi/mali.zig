const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mali = b.addModule("mali", .{
        .root_source_file = b.path("lib/mali.zig"),
        .target = target,
        .optimize = optimize,
    });
    const drm_dep = b.dependency("drm", .{
        .target = target,
        .optimize = optimize,
    });
    mali.addImport("drm", drm_dep.module("drm"));

    const tests = b.addTest(.{ .root_module = mali });
    const run_tests = b.addRunArtifact(tests);
    run_tests.skip_foreign_checks = true;

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);

    const info = b.addExecutable(.{
        .name = "mali-info",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/mali-info.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mali", .module = mali }},
        }),
    });
    const install_info = b.addInstallArtifact(info, .{});
    b.getInstallStep().dependOn(&install_info.step);

    const info_step = b.step("mali-info", "Build the read-only Mali DRM probe");
    info_step.dependOn(&install_info.step);

    const run_info = b.addRunArtifact(info);
    run_info.addPassthruArgs();
    const run_info_step = b.step("run-mali-info", "Run the Mali DRM probe");
    run_info_step.dependOn(&run_info.step);
}
