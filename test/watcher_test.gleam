import gleam/dict
import kangaroo/internal/watcher.{Added, Modified, Removed}

pub fn compile_command_compiles_test_modules_without_running_them_test() {
  assert watcher.compile_arguments("erlang", "erlang")
    == ["test", "--target", "erlang"]
  assert watcher.compile_arguments("javascript", "deno")
    == ["test", "--target", "javascript", "--runtime", "deno"]
  assert watcher.compile_environment() == [#("KANGAROO_COMPILE_ONLY", "1")]
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
  assert watcher.roots(["test", "test\\integration"], ["priv", "test"])
    == ["src", "test", "test/integration", "priv"]
}

pub fn javascript_compile_command_does_not_execute_tests_test() {
  assert watcher.compile_arguments("javascript", "bun")
    == ["test", "--target", "javascript", "--runtime", "bun"]
  assert watcher.compile_environment() == [#("KANGAROO_COMPILE_ONLY", "1")]
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
