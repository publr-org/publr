const std = @import("std");

/// `upgrade`: every fixture in `fixtures/upgrade` updated by `exe`
/// (`-Dupgrade-from=0.3.1` for one, `-Dupgrade-previous=<publr>` to prove a step back).
/// `upgrade-fixture`: the fixture of this version and the lived site carried on to it, made
/// by `exe` or by `-Dupgrade-binary=<publr>` (the release binary, in the Release workflow).
/// `migration-draft`: `src/lib/db/migrations/unreleased.zig` started from the schema's
/// changes since the last release. Returns the matrix's step, which `verify-full` runs.
pub fn add(builder: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step {
    std.debug.assert(builder.build_root.path != null);

    const from = builder.option([]const u8, "upgrade-from", "Only this fixture") orelse "";
    const previous = builder.option(
        []const u8,
        "upgrade-previous",
        "The previous minor's publr, to prove a step back",
    ) orelse "";
    const binary = builder.option(
        []const u8,
        "upgrade-binary",
        "Test and make fixtures with this publr (the release binary) instead of building one",
    );
    const releasing = builder.option(bool, "upgrade-releasing", "A release is being made") orelse
        false;
    const script = builder.addExecutable(.{
        .name = "upgrade",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/upgrade.zig"),
            .target = builder.graph.host,
            .optimize = .Debug,
        }),
    });
    const version = @import("smoke.zig").version(builder);

    const matrix = builder.addRunArtifact(script);

    matrix.addArg("matrix");
    add_binary(matrix, exe, binary);
    matrix.addArgs(&.{ version, builder.pathFromRoot("fixtures/upgrade") });
    matrix.addArgs(&.{ builder.pathFromRoot(".zig-cache/upgrade"), "--from", from });
    matrix.addArgs(&.{ "--previous", previous, "--releasing" });
    matrix.addArg(if (releasing) "true" else "false");
    matrix.has_side_effects = true;
    const upgrade = builder.step("upgrade", "Update every release's fixture with this build");

    upgrade.dependOn(&matrix.step);

    const fixture = builder.addRunArtifact(script);

    fixture.addArg("fixture");
    add_binary(fixture, exe, binary);

    fixture.addArgs(&.{ version, builder.pathFromRoot("fixtures/upgrade") });
    fixture.addArg(builder.pathFromRoot(".zig-cache/upgrade-fixture"));
    fixture.has_side_effects = true;
    builder.step("upgrade-fixture", "Make this version's fixture and carry the lived site")
        .dependOn(&fixture.step);

    const draft = builder.addRunArtifact(script);

    draft.addArg("draft");
    draft.addArtifactArg(exe);
    draft.addArgs(&.{ version, builder.pathFromRoot("fixtures/upgrade") });
    draft.addArg(builder.pathFromRoot(".zig-cache/migration-draft"));
    draft.has_side_effects = true;
    builder.step("migration-draft", "Draft the next migration against the last release")
        .dependOn(&draft.step);

    std.debug.assert(matrix.argv.items.len > 4);

    return &matrix.step;
}

/// `binary` when given (a release's own), else the one this build makes.
fn add_binary(run: *std.Build.Step.Run, exe: *std.Build.Step.Compile, binary: ?[]const u8) void {
    std.debug.assert(run.argv.items.len > 0);

    if (binary) |path| {
        run.addArg(path);
    } else {
        run.addArtifactArg(exe);
    }
}
