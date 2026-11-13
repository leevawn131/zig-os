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

    // Consistent optimization mode across build system and script entrypoints:
    // uses documented Zig 0.17.1 `b.option` and `b.graph.release_mode` APIs,
    // defaulting to ReleaseSafe (.safe) while honoring explicit -Doptimize=Debug / ReleaseSafe.
    const default_optimize: std.builtin.Optimize = switch (b.graph.release_mode) {
        .off, .any, .safe => .safe,
        .fast => .fast,
        .small => .small,
    };
    const optimize = b.option(
        std.builtin.Optimize,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSafe)",
    ) orelse default_optimize;
    const optimize_name = switch (optimize) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };

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
    const install_kernel = b.addInstallArtifact(kernel, .{});
    b.getInstallStep().dependOn(&install_kernel.step);

    const log_optimize = b.addSystemCommand(&.{
        "printf",
        "[BUILD] Optimization mode: %s\n",
        optimize_name,
    });
    log_optimize.setName("log optimize");
    log_optimize.step.dependOn(&install_kernel.step);
    b.getInstallStep().dependOn(&log_optimize.step);

    // ISO Packaging Step (depends on kernel install; never invokes `zig build` recursively)
    const iso_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/package-iso.sh",
        "--optimize",
        optimize_name,
    });
    iso_cmd.setName("package iso");
    iso_cmd.step.dependOn(b.getInstallStep());
    const iso_step = b.step("iso", "Build bootable hybrid ISO image");
    iso_step.dependOn(&iso_cmd.step);

    // Run QEMU Step
    const run_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/lib/qemu-runner.sh",
        "run",
        "--optimize",
        optimize_name,
    });
    run_cmd.setName("qemu run");
    run_cmd.step.dependOn(iso_step);
    const run_step = b.step("run", "Boot the OS in QEMU");
    run_step.dependOn(&run_cmd.step);

    // Debug QEMU Step
    const debug_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/lib/qemu-runner.sh",
        "debug",
        "--optimize",
        optimize_name,
    });
    debug_cmd.setName("qemu debug");
    debug_cmd.step.dependOn(iso_step);
    const debug_step = b.step("debug", "Launch QEMU waiting for GDB on :1234");
    debug_step.dependOn(&debug_cmd.step);

    // Smoke Test Step
    const test_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/lib/qemu-runner.sh",
        "test-boot",
        "--optimize",
        optimize_name,
    });
    test_cmd.setName("qemu test-boot");
    test_cmd.step.dependOn(iso_step);
    const boot_test_step = b.step("test-boot", "Run automated boot smoke test");
    boot_test_step.dependOn(&test_cmd.step);

    // Host Unit Test Step
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit_test.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    test_mod.addAnonymousImport("paging_math", .{
        .root_source_file = b.path("kernel/src/mm/paging_math.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    test_mod.addAnonymousImport("physical_math", .{
        .root_source_file = b.path("kernel/src/mm/physical_math.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    test_mod.addAnonymousImport("page_fault", .{
        .root_source_file = b.path("kernel/src/arch/x86_64/interrupts/page_fault.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    test_mod.addAnonymousImport("heap_layout", .{
        .root_source_file = b.path("kernel/src/mm/heap_layout.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    test_mod.addAnonymousImport("sse", .{
        .root_source_file = b.path("kernel/src/arch/x86_64/sse.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Stateful PMM Core Host Unit Tests (wired into the same `zig build test` step)
    const pmm_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/pmm_test.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    pmm_test_mod.addAnonymousImport("physical_core", .{
        .root_source_file = b.path("kernel/src/mm/physical_core.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    const pmm_tests = b.addTest(.{
        .name = "pmm_test",
        .root_module = pmm_test_mod,
    });
    const run_pmm_tests = b.addRunArtifact(pmm_tests);

    // Stateful VMM Core Host Unit Tests (wired into the same `zig build test` step)
    const vmm_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/vmm_test.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    vmm_test_mod.addAnonymousImport("virtual_core", .{
        .root_source_file = b.path("kernel/src/mm/virtual_core.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    const vmm_tests = b.addTest(.{
        .name = "vmm_test",
        .root_module = vmm_test_mod,
    });
    const run_vmm_tests = b.addRunArtifact(vmm_tests);

    // Stateful Heap Core Host Unit Tests (wired into the same `zig build test` step)
    const heap_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/heap_test.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    heap_test_mod.addAnonymousImport("heap_core", .{
        .root_source_file = b.path("kernel/src/mm/heap_core.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    const heap_tests = b.addTest(.{
        .name = "heap_test",
        .root_module = heap_test_mod,
    });
    const run_heap_tests = b.addRunArtifact(heap_tests);

    // Interrupt Vector Policy & Static Forbidden-INT Host Tests (F-03)
    const vector_policy_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/vector_policy_test.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    vector_policy_test_mod.addAnonymousImport("vectors", .{
        .root_source_file = b.path("kernel/src/arch/x86_64/interrupts/vectors.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    const vector_policy_opts = b.addOptions();
    vector_policy_opts.addOptionPathDirectory("kernel_dir", b.path("kernel"));
    vector_policy_test_mod.addOptions("build_options", vector_policy_opts);
    const vector_policy_tests = b.addTest(.{
        .name = "vector_policy_test",
        .root_module = vector_policy_test_mod,
    });
    const run_vector_policy_tests = b.addRunArtifact(vector_policy_tests);

    const unit_test_step = b.step("test", "Run host unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);
    unit_test_step.dependOn(&run_pmm_tests.step);
    unit_test_step.dependOn(&run_vmm_tests.step);
    unit_test_step.dependOn(&run_heap_tests.step);
    unit_test_step.dependOn(&run_vector_policy_tests.step);
}
