const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.path("src/json.zig");

    const json_module = b.addModule("json", .{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit and conformance tests");
    test_step.dependOn(&run_tests.step);

    // Conformance suite over the vendored fixture corpora. Fixtures are
    // discovered at test time via std.fs, so the corpus root is passed
    // as an absolute path on the build host; the suite then works from any
    // cwd there (not from a test binary moved to another machine).
    const conformance_options = b.addOptions();
    conformance_options.addOption([]const u8, "corpus_path", b.pathFromRoot("tests/corpus"));

    const conformance_module = b.createModule(.{
        .root_source_file = b.path("src/conformance.zig"),
        .target = target,
        .optimize = optimize,
    });
    conformance_module.addOptions("conformance_options", conformance_options);

    const conformance_tests = b.addTest(.{ .root_module = conformance_module });
    const run_conformance = b.addRunArtifact(conformance_tests);
    test_step.dependOn(&run_conformance.step);

    // Deterministic property/round-trip battery over the Document editor's
    // 7 invariants (see src/document_property.zig).
    const document_property_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/document_property.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_document_property = b.addRunArtifact(document_property_tests);
    test_step.dependOn(&run_document_property.step);

    // Microbenchmarks. Always built ReleaseFast for representative timing.
    // Fixture files are discovered at run time via the injected absolute
    // path, same pattern as the conformance corpus above.
    const bench_options = b.addOptions();
    bench_options.addOption([]const u8, "fixtures_path", b.pathFromRoot("bench/fixtures"));

    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "json", .module = json_module }},
    });
    bench_module.addOptions("bench_options", bench_options);

    const bench_exe = b.addExecutable(.{
        .name = "json-bench",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run microbenchmarks");
    bench_step.dependOn(&run_bench.step);

    // Random-input fuzzer. Sidesteps the broken `zig test --fuzz` mode in
    // 0.16.0 and gives us a portable, scriptable harness.
    const fuzz_exe = b.addExecutable(.{
        .name = "json-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "json", .module = json_module }},
        }),
    });
    b.installArtifact(fuzz_exe);
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| run_fuzz.addArgs(args);
    const fuzz_step = b.step("fuzz", "Run the random-input fuzzer (zig build fuzz -- [seed] [iterations])");
    fuzz_step.dependOn(&run_fuzz.step);

    // Runnable examples. `zig build examples` compiles all five;
    // `zig build example-<name>` compiles and runs that one.
    const example_names = [_][]const u8{ "basic", "typed", "edit", "spans", "stream" };
    const examples_step = b.step("examples", "Build all examples");
    for (example_names) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "json", .module = json_module }},
            }),
        });
        examples_step.dependOn(&exe.step);

        const run = b.addRunArtifact(exe);
        const run_step = b.step(
            b.fmt("example-{s}", .{name}),
            b.fmt("Build and run examples/{s}.zig", .{name}),
        );
        run_step.dependOn(&run.step);
    }

    // Generated reference documentation. `zig build docs` emits
    // zig-out/docs/index.html from the library's public API.
    const docs_obj = b.addObject(.{
        .name = "json-docs",
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate reference documentation into zig-out/docs/");
    docs_step.dependOn(&install_docs.step);
}
