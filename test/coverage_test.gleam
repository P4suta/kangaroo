import gleam/string
import kangaroo/internal/cli
import kangaroo/internal/command.{Ndjson, Pretty}
import kangaroo/internal/coverage.{FileCoverage}
import kangaroo/internal/coverage_run
import kangaroo/internal/fs

fn files() {
  [
    FileCoverage("src/a.gleam", [2, 3], [2]),
    FileCoverage("src/b.gleam", [1], []),
  ]
}

pub fn generated_workspace_entries_are_excluded_test() {
  assert fs.workspace_entry_excluded(".kangaroo-coverage-old")
  assert fs.workspace_entry_excluded(".kangaroo-coverage-owner")
  assert fs.workspace_entry_excluded(".vscode-test")
  assert fs.workspace_entry_excluded("node_modules")
  assert fs.workspace_entry_excluded("build")
  assert fs.workspace_entry_excluded("coverage")
  assert !fs.workspace_entry_excluded("src")
  assert !fs.workspace_entry_excluded("priv")
}

pub fn workspace_clone_reuses_dependencies_without_compiled_outputs_test() {
  let assert Ok(workspace) = fs.copy_to_temporary_workspace(".")
  let copied_config = fs.exists(workspace <> "/gleam.toml")
  let copied_dependencies =
    fs.is_directory(workspace <> "/build/packages/gleam_stdlib")
  let copied_compiled_output = fs.is_directory(workspace <> "/build/dev")
  let copied_nested_dependencies =
    fs.is_directory(
      workspace <> "/fixtures/watch_project/build/packages/gleam_stdlib",
    )
  let copied_nested_compiled_output =
    fs.is_directory(workspace <> "/fixtures/watch_project/build/dev")
  let copied_legitimate_coverage_source =
    fs.exists(
      workspace <> "/test/fixtures/watch_root/src/coverage/legitimate.gleam",
    )
  let copied_legitimate_build_source =
    fs.exists(
      workspace <> "/test/fixtures/watch_root/src/build/legitimate.gleam",
    )
  let assert Ok(Nil) =
    fs.write_file(workspace <> "/coverage/result.txt", "first")
  let assert Ok(Nil) =
    fs.write_file(workspace <> "/coverage/result.txt", "second")
  let assert Ok("second") = fs.read_file(workspace <> "/coverage/result.txt")
  let assert Ok(Nil) = fs.remove_tree(workspace)

  assert copied_config
  assert copied_dependencies
  assert copied_nested_dependencies
  assert copied_legitimate_coverage_source
  assert copied_legitimate_build_source
  assert !copied_compiled_output
  assert !copied_nested_compiled_output
  assert !fs.is_directory(workspace)
}

pub fn generated_names_inside_source_trees_are_not_pruned_test() {
  let assert Ok(files) =
    fs.list_source_files_recursive("test/fixtures/watch_root/src")

  assert list_contains_path_segment(files, "/coverage/legitimate.gleam")
  assert list_contains_path_segment(files, "/build/legitimate.gleam")
}

pub fn coverage_cleanup_requires_an_owned_workspace_marker_test() {
  let assert Ok(workspace) = fs.copy_to_temporary_workspace(".")
  let marker = workspace <> "/.kangaroo-coverage-owner"
  let assert Ok(Nil) = fs.remove_file(marker)

  let assert Error(_) = fs.remove_tree(workspace)
  assert fs.is_directory(workspace)

  // Restore the path-bound marker so the disposable fixture is recoverable.
  let assert Ok(Nil) = fs.write_exclusive(marker, workspace)
  let assert Ok(Nil) = fs.remove_tree(workspace)
  assert !fs.is_directory(workspace)
}

pub fn workspace_source_listing_prunes_every_generated_tree_test() {
  let assert Ok(files) = fs.list_workspace_files_recursive(".")
  assert files != []
  assert !list_contains_root_path(files, "build/")
  assert !list_contains_root_path(files, "coverage/")
  assert !list_contains_path_segment(files, "/.vscode-test/")
  assert !list_contains_path_segment(files, "/node_modules/")
  assert !list_contains_path_segment(files, "/.kangaroo-coverage-")
}

fn list_contains_root_path(files: List(String), prefix: String) -> Bool {
  case files {
    [] -> False
    [file, ..rest] -> {
      let file = string.replace(file, "\\", "/") |> string.remove_prefix("./")
      string.starts_with(file, prefix) || list_contains_root_path(rest, prefix)
    }
  }
}

fn list_contains_path_segment(files: List(String), segment: String) -> Bool {
  case files {
    [] -> False
    [file, ..rest] ->
      string.contains(string.replace(file, "\\", "/"), segment)
      || list_contains_path_segment(rest, segment)
  }
}

pub fn percentages_include_unexecuted_files_and_executable_lines_test() {
  let assert [first, ..] = files()
  assert coverage.percentage(files()) == 33
  assert coverage.file_percentage(first) == 50
}

pub fn overall_and_per_file_thresholds_are_enforced_together_test() {
  assert coverage.violations(files(), 34, 50)
    == [
      "overall coverage 33% is below 34%",
      "src/b.gleam coverage 0% is below 50%",
    ]
}

pub fn lcov_includes_zero_hit_line_records_test() {
  let output = coverage.lcov(files())
  assert string.contains(output, "SF:src/a.gleam\n")
  assert string.contains(output, "DA:2,1\nDA:3,0\n")
  assert string.contains(output, "LF:2\nLH:1\nend_of_record")
}

pub fn cobertura_escapes_files_and_reports_line_rates_test() {
  let output = coverage.cobertura([FileCoverage("src/a&b.gleam", [2], [2])])
  assert string.contains(output, "line-rate=\"1.0\"")
  assert string.contains(output, "filename=\"src/a&amp;b.gleam\"")
  assert string.contains(output, "line number=\"2\" hits=\"1\"")
}

pub fn collector_hits_are_normalised_to_gleam_sources_test() {
  assert coverage.module_for_path("src/foo/bar.gleam") == Ok("foo/bar")
  assert coverage.from_hits("src/foo/bar.gleam", [
      #(3, 0),
      #(2, 4),
      #(3, 2),
      #(0, 9),
    ])
    == FileCoverage("src/foo/bar.gleam", [2, 3], [2, 3])
}

pub fn probe_hits_are_parsed_and_corrupt_records_rejected_test() {
  assert coverage.parse_hits("src/a.gleam\t2\nsrc/a.gleam\t2\nsrc/b.gleam\t9\n")
    == Ok([
      #("src/a.gleam", 2),
      #("src/a.gleam", 2),
      #("src/b.gleam", 9),
    ])
  assert coverage.parse_hits("src/a.gleam\tnot-a-line\n")
    == Error("invalid coverage probe record on line 1")
}

pub fn merging_hits_retains_unexecuted_sources_test() {
  assert coverage.with_hits(files(), [
      #("src/a.gleam", 2),
      #("src/a.gleam", 99),
    ])
    == [
      FileCoverage("src/a.gleam", [2, 3], [2]),
      FileCoverage("src/b.gleam", [1], []),
    ]
}

pub fn instrumentation_only_changes_the_disposable_clone_test() {
  let assert Ok(prepared) =
    coverage_run.prepare(".", ["test/v1/passing.gleam"], [])
  let assert [FileCoverage(path, executable, [])] = prepared.files
  let assert Ok(cloned) =
    fs.read_file(prepared.workspace <> "/test/v1/passing.gleam")
  let assert Ok(original) = fs.read_file("test/v1/passing.gleam")
  let assert Ok(Nil) = coverage_run.cleanup(prepared)
  assert path == "test/v1/passing.gleam"
  assert executable != []
  assert string.contains(cloned, "kangaroo_coverage_probe.hit")
  assert !string.contains(original, "kangaroo_coverage_probe.hit")
  assert !fs.is_directory(prepared.workspace)
}

pub fn exact_instrumentation_validation_does_not_write_source_test() {
  let assert Ok(before) = fs.read_file("src/kangaroo.gleam")
  let assert Ok(1) = coverage_run.validate(".", ["src/kangaroo.gleam"], [])
  let assert Ok(after) = fs.read_file("src/kangaroo.gleam")
  assert after == before
}

pub fn terminal_lcov_and_cobertura_outputs_share_one_result_test() {
  let assert Ok(outputs) =
    coverage_run.outputs(files(), ["terminal", "lcov", "cobertura"])
  let assert [
    coverage_run.TerminalOutput(terminal),
    coverage_run.FileOutput("coverage/lcov.info", lcov),
    coverage_run.FileOutput("coverage/cobertura.xml", cobertura),
  ] = outputs
  assert string.contains(terminal, "TOTAL  33%")
  assert string.contains(lcov, "SF:src/a.gleam")
  assert string.contains(cobertura, "<coverage")
}

pub fn cli_coverage_reporters_completely_override_configuration_test() {
  assert coverage_run.selected_reporters(["terminal"], []) == ["terminal"]
  assert coverage_run.selected_reporters(["terminal"], [
      "lcov",
      "lcov",
      "cobertura",
    ])
    == ["lcov", "cobertura"]
}

pub fn failed_tests_or_thresholds_use_exit_one_test() {
  assert coverage_run.final_exit_code(0, []) == 0
  assert coverage_run.final_exit_code(1, []) == 1
  assert coverage_run.final_exit_code(0, ["below minimum"]) == 1
  assert coverage_run.final_exit_code(2, []) == 2
}

pub fn coverage_cleanup_errors_never_hide_the_primary_failure_test() {
  assert coverage_run.combine_cleanup(Ok(42), Ok(Nil)) == Ok(42)
  assert coverage_run.combine_cleanup(Ok(42), Error("locked"))
    == Error("could not remove coverage workspace: locked")
  assert coverage_run.combine_cleanup(Error("collection failed"), Ok(Nil))
    == Error("collection failed")
  assert coverage_run.combine_cleanup(
      Error("collection failed"),
      Error("locked"),
    )
    == Error("collection failed\ncould not remove coverage workspace: locked")
}

pub fn coverage_ndjson_keeps_compiler_logs_off_stdout_test() {
  let event = "{\"type\":\"run_started\",\"run_id\":1,\"case_count\":2}"
  assert cli.partition_coverage_ndjson(
      "  Compiling dependency\r\n" <> event <> "\n\n",
    )
    == #([event], ["  Compiling dependency"])
}

pub fn coverage_ndjson_keeps_the_terminal_table_off_stdout_test() {
  assert !cli.coverage_terminal_uses_stdout(Ndjson)
  assert cli.coverage_terminal_uses_stdout(Pretty)
}
