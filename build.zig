const std = @import("std");

const qaws_version = "0.2.5";

const ReleaseTarget = struct {
    triple: []const u8,
    exe_ext: []const u8 = "",
};

const release_targets = [_]ReleaseTarget{
    .{ .triple = "x86_64-linux-musl" },
    .{ .triple = "x86_64-linux-gnu" },
    .{ .triple = "aarch64-linux-musl" },
    .{ .triple = "aarch64-linux-gnu" },
    .{ .triple = "arm-linux-musleabihf" },
    .{ .triple = "riscv64-linux-musl" },
    .{ .triple = "aarch64-linux-android" },
    .{ .triple = "aarch64-macos" },
    .{ .triple = "x86_64-macos" },
    .{ .triple = "x86_64-windows-gnu", .exe_ext = ".exe" },
    .{ .triple = "aarch64-windows-gnu", .exe_ext = ".exe" },
    .{ .triple = "x86_64-freebsd" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = addQawsExecutable(b, "qaws", target, optimize);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run qaws");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_cmd = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);

    const release_step = b.step("release", "Build release binaries into the install prefix's dist/ directory");
    for (release_targets) |spec| {
        const release_target = b.resolveTargetQuery(
            std.Build.parseTargetQuery(.{ .arch_os_abi = spec.triple }) catch unreachable,
        );
        const release_name = b.fmt("qaws-{s}", .{spec.triple});
        const release_exe = addQawsExecutable(b, release_name, release_target, .ReleaseFast);
        const artifact_name = b.fmt("qaws-{s}-{s}{s}", .{ qaws_version, spec.triple, spec.exe_ext });
        const install_artifact = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{ .custom = "dist" } },
            .dest_sub_path = artifact_name,
            .pdb_dir = .disabled,
            .implib_dir = .disabled,
            .h_dir = .disabled,
            .compiler_rt_dyn_lib_dir = .disabled,
        });
        release_step.dependOn(&install_artifact.step);
    }
}

fn addQawsExecutable(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
        .version = .{ .major = 0, .minor = 2, .patch = 5 },
    });
    if (target.result.abi.isAndroid()) {
        exe.pie = true;
    }
    return exe;
}
