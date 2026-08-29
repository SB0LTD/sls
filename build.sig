// sls — Sig Language Server. Canonical zero-allocation Sig build graph.
//
// Built with the native `sig_build` API (Sig 0.4.0+). The legacy `std.Build`
// graph is intentionally not used: the in-process build runner drives a
// `sig_build.Build_Context`, so every step is expressed against that API.
//
// Reusable infrastructure is consumed from the sibling `zpm` package library
// by relative source path (development-hierarchy: reusable code lives in zpm,
// project-specific code lives here). No allocator, no runtime std I/O.
//
// Modules are wired by name so files in different src/ subdirectories can
// import each other without escaping their module path (a bare-name import
// resolves through the step's registered import set).
//
//   Build:  sig build
//   Run:    sig build run
//   Test:   sig build test
const sig_build = @import("sig_build");
const builtin = @import("builtin");

// ── Source paths ────────────────────────────────────────────────────────────
// zpm package library (path dependency → ../zpm)
const zpm_json = "../zpm/src/core/json.sig";
// sls-local modules
const p_document = "src/core/document.sig";
const p_position = "src/core/position.sig";
const p_symbols = "src/core/symbols.sig";
const p_jwrite = "src/lsp/jwrite.sig";
const p_message = "src/lsp/message.sig";
const p_loop = "src/lsp/loop.sig";
const p_stdio = "src/platform/stdio.sig";
const p_server = "src/server/server.sig";

fn noopStep(ctx: *sig_build.Step_Context) sig_build.SigError!void {
    _ = ctx;
}

/// Build a fixed-buffer import entry (name → source path) for compile/test steps.
fn importEntry(name: []const u8, path: []const u8) sig_build.Import_Entry {
    var entry: sig_build.Import_Entry = .{};
    @memcpy(entry.name[0..name.len], name);
    entry.name_len = name.len;
    @memcpy(entry.path[0..path.len], path);
    entry.path_len = path.len;
    return entry;
}

// ── Import sets (each includes the transitive closure it needs) ──────────────
const no_imports = [_]sig_build.Import_Entry{};

const message_imports = [_]sig_build.Import_Entry{
    importEntry("json", zpm_json),
};

const server_imports = [_]sig_build.Import_Entry{
    importEntry("json", zpm_json),
    importEntry("message", p_message),
    importEntry("jwrite", p_jwrite),
    importEntry("document", p_document),
    importEntry("position", p_position),
    importEntry("symbols", p_symbols),
};

const app_imports = [_]sig_build.Import_Entry{
    importEntry("json", zpm_json),
    importEntry("message", p_message),
    importEntry("jwrite", p_jwrite),
    importEntry("document", p_document),
    importEntry("position", p_position),
    importEntry("symbols", p_symbols),
    importEntry("stdio", p_stdio),
    importEntry("server", p_server),
    importEntry("loop", p_loop),
};

fn runApp(ctx: *sig_build.Step_Context) sig_build.SigError!void {
    const build_ctx = ctx.build_ctx;
    const prefix = build_ctx.install_prefix[0..build_ctx.install_prefix_len];
    const suffix = if (builtin.os.tag == .windows) "/bin/sls.exe" else "/bin/sls";
    var path: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    if (prefix.len + suffix.len > path.len) return error.BufferTooSmall;
    @memcpy(path[0..prefix.len], prefix);
    @memcpy(path[prefix.len .. prefix.len + suffix.len], suffix);
    var command: sig_build.Command_Buffer = .{};
    try command.appendArg(path[0 .. prefix.len + suffix.len]);
    var stderr: [sig_build.STDERR_CAPTURE_SIZE]u8 = undefined;
    var stderr_len: usize = 0;
    const exit_code = try sig_build.runCommand(&command, &stderr, &stderr_len, ctx.io);
    if (exit_code != 0) {
        sig_build.printMsg(ctx.io, "sls exited with failure: {s}", .{stderr[0..stderr_len]});
        return error.BufferTooSmall;
    }
}

/// Wire a named import (name → path) onto a registered module.
fn wire(ctx: *sig_build.Build_Context, module: sig_build.Module_Handle, name: []const u8, path: []const u8) !void {
    try ctx.addImport(module, name, path);
}

pub fn build(ctx: *sig_build.Build_Context) !void {
    // Register every module and wire its own imports. The compile/test steps
    // then only need to name their *root* imports; the runner walks each
    // module's import set transitively to emit the full --dep/-M closure.
    _ = try ctx.addModule("json", zpm_json);
    _ = try ctx.addModule("jwrite", p_jwrite);
    _ = try ctx.addModule("document", p_document);
    _ = try ctx.addModule("position", p_position);
    _ = try ctx.addModule("symbols", p_symbols);
    _ = try ctx.addModule("stdio", p_stdio);

    const message = try ctx.addModule("message", p_message);
    try wire(ctx, message, "json", zpm_json);

    const server = try ctx.addModule("server", p_server);
    try wire(ctx, server, "json", zpm_json);
    try wire(ctx, server, "message", p_message);
    try wire(ctx, server, "jwrite", p_jwrite);
    try wire(ctx, server, "document", p_document);
    try wire(ctx, server, "position", p_position);
    try wire(ctx, server, "symbols", p_symbols);

    // The shared transport loop depends on message + server.
    const loop_mod = try ctx.addModule("loop", p_loop);
    try wire(ctx, loop_mod, "message", p_message);
    try wire(ctx, loop_mod, "server", p_server);
    try wire(ctx, loop_mod, "json", zpm_json);
    try wire(ctx, loop_mod, "jwrite", p_jwrite);
    try wire(ctx, loop_mod, "document", p_document);
    try wire(ctx, loop_mod, "position", p_position);
    try wire(ctx, loop_mod, "symbols", p_symbols);

    // The application executable — root module src/main.sig with the full
    // transitive import closure registered by name.
    const executable = try ctx.addCompileStep(.{
        .source_path = "src/main.sig",
        .output_name = "sls",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .imports = &app_imports,
        .compiler_path = "",
    });

    const install = try ctx.addStep("install", "Build the sls language server", &noopStep);
    try ctx.addDependency(install, executable);

    const run = try ctx.addStep("run", "Build and run the sls language server", &runApp);
    try ctx.addDependency(run, executable);

    // Aggregate test step. Every module with logic contributes its own test
    // root so failures are isolated per unit and cached independently.
    const test_all = try ctx.addStep("test", "Run all sls tests", &noopStep);

    _ = try addTest(ctx, test_all, "test-document", p_document, &no_imports);
    _ = try addTest(ctx, test_all, "test-position", p_position, &no_imports);
    _ = try addTest(ctx, test_all, "test-symbols", p_symbols, &no_imports);
    _ = try addTest(ctx, test_all, "test-jwrite", p_jwrite, &no_imports);
    _ = try addTest(ctx, test_all, "test-message", p_message, &message_imports);
    _ = try addTest(ctx, test_all, "test-server", p_server, &server_imports);
    _ = try addTest(ctx, test_all, "test-main", "src/main.sig", &app_imports);
}

fn addTest(
    ctx: *sig_build.Build_Context,
    aggregate: sig_build.Step_Handle,
    name: []const u8,
    source_path: []const u8,
    imports: []const sig_build.Import_Entry,
) !sig_build.Step_Handle {
    const step = try ctx.addTestStep(.{
        .name = name,
        .source_path = source_path,
        .imports = imports,
    });
    try ctx.addDependency(aggregate, step);
    return step;
}
