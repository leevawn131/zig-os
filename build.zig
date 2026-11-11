const std = @import("std");

pub fn build(b: *std.Build) void {
    const x86 = std.Target.x86;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = x86.featureSet(&[_]x86.Feature{
            .x87,
            .mmx,
            .sse,
            .sse2,
            .avx,
            .avx2,
        }),
        .cpu_features_add = x86.featureSet(&[_]x86.Feature{
            .soft_float,
        }),
    });

    const optimize = b.standardOptimizeOption(.{});

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
    });

    kernel_mod.addAssemblyFile(b.path("kernel/src/arch/x86_64/interrupts/stubs.s"));

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = kernel_mod,
        .use_llvm = true,
        .use_lld = true,
    });

    kernel.setLinkerScript(b.path("kernel/linker.ld"));
    b.installArtifact(kernel);

    // Build ISO Step
    const iso_cmd = b.addSystemCommand(&.{ "bash", "scripts/build.sh", "iso" });
    iso_cmd.step.dependOn(b.getInstallStep());
    const iso_step = b.step("iso", "Build bootable hybrid ISO image");
    iso_step.dependOn(&iso_cmd.step);

    // Run QEMU Step
    const run_cmd = b.addSystemCommand(&.{ "bash", "scripts/run.sh" });
    run_cmd.step.dependOn(iso_step);
    const run_step = b.step("run", "Boot the OS in QEMU");
    run_step.dependOn(&run_cmd.step);

    // Debug QEMU Step
    const debug_cmd = b.addSystemCommand(&.{ "bash", "scripts/debug.sh" });
    debug_cmd.step.dependOn(iso_step);
    const debug_step = b.step("debug", "Launch QEMU waiting for GDB on :1234");
    debug_step.dependOn(&debug_cmd.step);

    // Smoke Test Step
    const test_cmd = b.addSystemCommand(&.{ "bash", "scripts/test-boot.sh" });
    test_cmd.step.dependOn(iso_step);
    const boot_test_step = b.step("test-boot", "Run automated boot smoke test");
    boot_test_step.dependOn(&test_cmd.step);

    // Host Unit Test Step
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit_test.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("test", "Run host unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);
}
