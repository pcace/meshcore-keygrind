const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan_dep = b.dependency("vulkan_zig", .{ .registry = vulkan_headers.path("registry/vk.xml"), });
    const vulkan_module = vulkan_dep.module("vulkan-zig");

    const spirv_compile = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.2", "-O", "-o" });
    const spirv_output = spirv_compile.addOutputFileArg("vanity.spv");
    spirv_compile.addFileArg(b.path("src/shaders/vanity.comp"));

    const spirv_module = b.addModule("spirv", .{
        .root_source_file = b.addWriteFiles().add("spirv.zig", \\pub const EMBEDDED_SPIRV = @embedFile("vanity.spv");
        ),
    });
    spirv_module.addAnonymousImport("vanity.spv", .{ .root_source_file = spirv_output });

    const exe = b.addExecutable(.{
        .name = "grincel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vulkan", .module = vulkan_module },
                .{ .name = "spirv", .module = spirv_module },
            },
        }),
    });

    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
