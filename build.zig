const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "audio_preprocessor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Link FFmpeg libraries
    exe.linkSystemLibrary("avcodec");
    exe.linkSystemLibrary("avformat");
    exe.linkSystemLibrary("avutil");
    exe.linkSystemLibrary("swresample");

    // Add include paths for FFmpeg headers (common locations)
    exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the audio preprocessor");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe_unit_tests.linkSystemLibrary("avcodec");
    exe_unit_tests.linkSystemLibrary("avformat");
    exe_unit_tests.linkSystemLibrary("avutil");
    exe_unit_tests.linkSystemLibrary("swresample");
    exe_unit_tests.root_module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe_unit_tests.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
