const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Run Zig test suites for the repo");

    const relay_tests = b.addSystemCommand(&.{ "zig", "build", "test" });
    relay_tests.setCwd(b.path("apps/relay"));
    relay_tests.setName("zig build test (apps/relay)");
    test_step.dependOn(&relay_tests.step);

    const cli_tests = b.addSystemCommand(&.{ "zig", "build", "test" });
    cli_tests.setCwd(b.path("apps/cli"));
    cli_tests.setName("zig build test (apps/cli)");
    test_step.dependOn(&cli_tests.step);

    const wasm_check = b.addSystemCommand(&.{ "zig", "build", "check" });
    wasm_check.setCwd(b.path("packages/wasm"));
    wasm_check.setName("zig build check (packages/wasm)");

    const check_step = b.step("check", "Run Zig compile checks for the repo");
    check_step.dependOn(&relay_tests.step);
    check_step.dependOn(&cli_tests.step);
    check_step.dependOn(&wasm_check.step);
}
