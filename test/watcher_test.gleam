import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/vm
import kangaroo/internal/watcher.{Added, Modified, Removed}
import kangaroo/sys

@external(erlang, "kangaroo_cli_test_ffi", "temporary_directory")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "temporary_directory")
fn temporary_directory() -> String

@external(erlang, "kangaroo_cli_test_ffi", "set_file_mode")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "set_file_mode")
fn set_file_mode(path: String, mode: Int) -> Bool

@external(erlang, "kangaroo_cli_test_ffi", "make_directory_symlink")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "make_directory_symlink")
fn make_directory_symlink(target: String, link: String) -> Bool

pub fn compile_command_compiles_test_modules_without_running_them_test() {
  assert watcher.compile_arguments("erlang", "erlang")
    == ["test", "--target", "erlang"]
  assert watcher.compile_arguments("javascript", "deno")
    == ["test", "--target", "javascript", "--runtime", "deno"]
  assert watcher.compile_environment()
    == [#("KANGAROO_COMPILE_ONLY", "kangaroo-watch-compile-v1")]
  assert watcher.compile_only_requested(Some("kangaroo-watch-compile-v1"))
  assert !watcher.compile_only_requested(Some("1"))
  assert !watcher.compile_only_requested(None)
}

pub fn snapshot_diff_detects_add_modify_and_remove_test() {
  let before =
    dict.from_list([
      #("src/changed.gleam", "old bytes"),
      #("src/removed.gleam", "gone"),
    ])
  let after =
    dict.from_list([
      #("src/added.gleam", "new"),
      #("src/changed.gleam", "new bytes"),
    ])
  assert watcher.diff(before, after)
    == [
      Added("src/added.gleam"),
      Modified("src/changed.gleam"),
      Removed("src/removed.gleam"),
    ]
}

pub fn rename_is_normalised_as_add_and_remove_test() {
  assert watcher.diff(
      dict.from_list([#("test\\old.gleam", "same")]),
      dict.from_list([#("test/new.gleam", "same")]),
    )
    == [Added("test/new.gleam"), Removed("test/old.gleam")]
}

pub fn gleam_ffi_config_and_manifest_files_are_watched_test() {
  assert watcher.is_watched("src/a.gleam")
  assert watcher.is_watched("src/a.erl")
  assert watcher.is_watched("src/a.mjs")
  assert watcher.is_watched("gleam.toml")
  assert watcher.is_watched("manifest.toml")
  assert !watcher.is_watched("README.md")
}

pub fn watch_roots_are_unique_and_normalised_test() {
  assert watcher.roots(["test/", "test\\integration"], ["priv/", "./test"])
    == ["src", "dev", "test", "priv"]
}

pub fn watch_always_covers_every_gleam_development_source_root_test() {
  assert watcher.roots(["test/unit"], []) == ["src", "dev", "test"]
  assert watcher.roots(["src/spec"], ["snapshots"])
    == ["src", "dev", "test", "snapshots"]
}

pub fn project_root_snapshot_prunes_generated_trees_test() {
  let assert Ok(snapshot) =
    watcher.snapshot_project("test/fixtures/watch_root", ["."])
  assert snapshot
    |> dict.keys
    |> list.sort(string.compare)
    == [
      "src/build/legitimate.gleam",
      "src/coverage/legitimate.gleam",
      "src/example.gleam",
    ]
}

pub fn watched_file_read_errors_are_reported_test() {
  case vm.operating_system(), vm.target(), vm.runtime_name() {
    "windows", _, _ -> Nil
    _, "javascript", runtime if runtime != "node" -> Nil
    _, _, _ -> {
      let directory = temporary_directory()
      let name =
        "kangaroo-watcher-unreadable-"
        <> int.to_string(sys.now_ms())
        <> ".gleam"
      let path = directory <> "/" <> name
      let assert Ok(Nil) = fs.write_file(path, "pub fn value() { 1 }")
      assert set_file_mode(path, 0)
      let snapshot = watcher.snapshot_project(directory, [name])
      let restored = set_file_mode(path, 384)
      let removed = fs.remove_file(path)
      assert restored
      assert removed == Ok(Nil)
      let assert Error(message) = snapshot
      assert string.contains(message, "could not read watched file `" <> name)
    }
  }
}

pub fn javascript_compile_command_does_not_execute_tests_test() {
  assert watcher.compile_arguments("javascript", "bun")
    == ["test", "--target", "javascript", "--runtime", "bun"]
  assert watcher.compile_environment()
    == [#("KANGAROO_COMPILE_ONLY", "kangaroo-watch-compile-v1")]
}

pub fn only_stale_compiler_products_are_invalidated_test() {
  assert watcher.stale_build_files("/project", "sample_app", "javascript", [
      Modified("test/unit/math_test.gleam"),
      Modified("test/math_test_ffi.mjs"),
      Modified("test/math_test_ffi.erl"),
      Added("src/new_module.gleam"),
      Removed("src/old/module.gleam"),
    ])
    == [
      "/project/build/dev/javascript/sample_app/_gleam_artefacts/unit@math_test.cache_meta",
      "/project/build/dev/javascript/sample_app/math_test_ffi.mjs",
      "/project/build/dev/javascript/sample_app/_gleam_artefacts/old@module.cache_meta",
      "/project/build/dev/javascript/sample_app/_gleam_artefacts/old@module.cache",
      "/project/build/dev/javascript/sample_app/old/module.mjs",
    ]
}

pub fn dev_source_and_native_edits_invalidate_compiler_products_test() {
  assert watcher.stale_build_files("/project", "sample_app", "javascript", [
      Modified("dev/integration/support.gleam"),
      Modified("dev/integration/support_ffi.mjs"),
    ])
    == [
      "/project/build/dev/javascript/sample_app/_gleam_artefacts/integration@support.cache_meta",
      "/project/build/dev/javascript/sample_app/integration/support_ffi.mjs",
    ]
}

pub fn stale_build_invalidation_cannot_escape_the_package_build_test() {
  assert watcher.stale_build_files("/project", "sample_app", "javascript", [
      Removed("test/../../../../tmp/user-file.mjs"),
      Removed("src/../../../user-file.gleam"),
    ])
    == []
  assert watcher.stale_build_files("/project", "../../outside", "javascript", [
      Removed("test/user-file.mjs"),
    ])
    == []
}

pub fn stale_build_invalidation_never_follows_directory_symlinks_test() {
  let assert Ok(workspace) = fs.copy_to_temporary_workspace(".")
  let victim = workspace <> "/src/watch_victim.cache_meta"
  let package_build = workspace <> "/build/dev/javascript/kangaroo"
  let assert Ok(Nil) = fs.write_file(victim, "preserve")
  let assert Ok(Nil) = fs.write_file(package_build <> "/placeholder", "")
  let created =
    make_directory_symlink(
      workspace <> "/src",
      package_build <> "/_gleam_artefacts",
    )
  let invalidated =
    watcher.invalidate_stale_build_files(workspace, "javascript", [
      Modified("src/watch_victim.gleam"),
    ])
  let retained = fs.read_file(victim)
  let cleaned = fs.remove_tree(workspace)
  assert cleaned == Ok(Nil)

  case created {
    True -> {
      let assert Error(message) = invalidated
      assert string.contains(message, "symbolic link")
      assert retained == Ok("preserve")
    }
    // Some Windows environments do not grant symlink creation privileges;
    // Linux and macOS still exercise the destructive boundary.
    False -> Nil
  }
}

pub fn cancellable_child_run_command_is_target_specific_test() {
  assert watcher.run_arguments("javascript", [
      "test/a.gleam::a_test",
      "--reporter",
      "dot",
    ])
    == [
      "test",
      "--target",
      "javascript",
      "--",
      "test/a.gleam::a_test",
      "--reporter",
      "dot",
    ]
}

pub fn child_generations_preserve_the_javascript_runtime_test() {
  assert watcher.run_arguments_for("javascript", "bun", ["--tag", "unit"])
    == [
      "test",
      "--target",
      "javascript",
      "--runtime",
      "bun",
      "--",
      "--tag",
      "unit",
    ]
  assert watcher.run_arguments_for("erlang", "erlang", [])
    == ["test", "--target", "erlang", "--"]
}

pub fn compiled_erlang_generations_run_without_a_launcher_test() {
  assert watcher.generation_executable("erlang") == "erl"
  assert watcher.generation_arguments_for("erlang", "erlang", [
      "test/math_test.gleam::addition_test",
      "--reporter",
      "dot",
    ])
    == [
      "-noshell",
      "-eval",
      "code:add_paths(filelib:wildcard(\"build/dev/erlang/*/ebin\")), kangaroo:main().",
      "-extra",
      "test/math_test.gleam::addition_test",
      "--reporter",
      "dot",
    ]
  assert watcher.generation_executable("javascript") == "gleam"
}

pub fn coordinator_starts_through_the_public_run_command_test() {
  assert watcher.coordinator_arguments_for("javascript", "deno", [
      "watch",
      "--tag",
      "unit",
    ])
    == [
      "run",
      "--target",
      "javascript",
      "--runtime",
      "deno",
      "-m",
      "kangaroo",
      "--",
      "watch",
      "--tag",
      "unit",
    ]
  assert watcher.coordinator_arguments_for("erlang", "erlang", ["watch"])
    == ["run", "--target", "erlang", "-m", "kangaroo", "--", "watch"]
}
