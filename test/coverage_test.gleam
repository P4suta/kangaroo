import gleam/string
import kangaroo/internal/coverage.{FileCoverage}
import kangaroo/internal/coverage_run
import kangaroo/internal/fs
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

fn files() {
  [
    FileCoverage("src/a.gleam", [2, 3], [2]),
    FileCoverage("src/b.gleam", [1], []),
  ]
}

pub fn generated_workspace_entries_are_excluded_test() {
  assert fs.workspace_entry_excluded(".kangaroo-coverage-old")
  assert fs.workspace_entry_excluded(".vscode-test")
  assert fs.workspace_entry_excluded("node_modules")
  assert fs.workspace_entry_excluded("build")
  assert fs.workspace_entry_excluded("coverage")
  assert !fs.workspace_entry_excluded("src")
  assert !fs.workspace_entry_excluded("priv")
}

pub fn workspace_clone_reuses_dependencies_without_compiled_outputs_test() {
  let assert Ok(workspace) = fs.copy_to_temporary_workspace(".")
  let copied_dependencies =
    fs.is_directory(workspace <> "/build/packages/gleam_stdlib")
  let copied_compiled_output = fs.is_directory(workspace <> "/build/dev")
  let assert Ok(Nil) = fs.remove_tree(workspace)

  assert copied_dependencies
  assert !copied_compiled_output
}

pub fn workspace_source_listing_prunes_every_generated_tree_test() {
  let assert Ok(files) = fs.list_workspace_files_recursive(".")
  assert files != []
  assert !list_contains_path_segment(files, "/build/")
  assert !list_contains_path_segment(files, "/.vscode-test/")
  assert !list_contains_path_segment(files, "/node_modules/")
  assert !list_contains_path_segment(files, "/.kangaroo-coverage-")
}

fn list_contains_path_segment(files: List(String), segment: String) -> Bool {
  case files {
    [] -> False
    [file, ..rest] ->
      string.contains(string.replace(file, "\\", "/"), segment)
      || list_contains_path_segment(rest, segment)
  }
}

pub fn suites() {
  [
    suite("coverage model", [
      it("includes unexecuted files and executable lines in percentages", fn() {
        let assert [first, ..] = files()
        expect(coverage.percentage(files())) |> to_equal(33)
        expect(coverage.file_percentage(first))
        |> to_equal(50)
      }),
      it("enforces overall and per-file thresholds together", fn() {
        expect(coverage.violations(files(), 34, 50))
        |> to_equal([
          "overall coverage 33% is below 34%",
          "src/b.gleam coverage 0% is below 50%",
        ])
      }),
      it("renders valid LCOV line records including zero hits", fn() {
        let output = coverage.lcov(files())
        expect(string.contains(output, "SF:src/a.gleam\n")) |> to_be_true()
        expect(string.contains(output, "DA:2,1\nDA:3,0\n")) |> to_be_true()
        expect(string.contains(output, "LF:2\nLH:1\nend_of_record"))
        |> to_be_true()
      }),
      it("renders escaped Cobertura files and line rates", fn() {
        let output =
          coverage.cobertura([
            FileCoverage("src/a&b.gleam", [2], [2]),
          ])
        expect(string.contains(output, "line-rate=\"1.0\"")) |> to_be_true()
        expect(string.contains(output, "filename=\"src/a&amp;b.gleam\""))
        |> to_be_true()
        expect(string.contains(output, "line number=\"2\" hits=\"1\""))
        |> to_be_true()
      }),
      it("normalises collector hits onto a Gleam source file", fn() {
        expect(coverage.module_for_path("src/foo/bar.gleam"))
        |> to_equal(Ok("foo/bar"))
        expect(
          coverage.from_hits("src/foo/bar.gleam", [
            #(3, 0),
            #(2, 4),
            #(3, 2),
            #(0, 9),
          ]),
        )
        |> to_equal(FileCoverage("src/foo/bar.gleam", [2, 3], [2, 3]))
      }),
      it("parses probe hits and rejects corrupt partial records", fn() {
        expect(coverage.parse_hits(
          "src/a.gleam\t2\nsrc/a.gleam\t2\nsrc/b.gleam\t9\n",
        ))
        |> to_equal(
          Ok([
            #("src/a.gleam", 2),
            #("src/a.gleam", 2),
            #("src/b.gleam", 9),
          ]),
        )
        expect(coverage.parse_hits("src/a.gleam\tnot-a-line\n"))
        |> to_equal(Error("invalid coverage probe record on line 1"))
      }),
      it("merges hits while retaining every unexecuted source", fn() {
        expect(
          coverage.with_hits(files(), [
            #("src/a.gleam", 2),
            #("src/a.gleam", 99),
          ]),
        )
        |> to_equal([
          FileCoverage("src/a.gleam", [2, 3], [2]),
          FileCoverage("src/b.gleam", [1], []),
        ])
      }),
      it("copies coverage work into a disposable workspace", fn() {
        let assert Ok(workspace) = fs.copy_to_temporary_workspace(".")
        let copied_config = fs.exists(workspace <> "/gleam.toml")
        let copied_dependencies =
          fs.is_directory(workspace <> "/build/packages/gleam_stdlib")
        let copied_compiled_output = fs.is_directory(workspace <> "/build/dev")
        let assert Ok(Nil) =
          fs.write_file(workspace <> "/coverage/result.txt", "first")
        let assert Ok(Nil) =
          fs.write_file(workspace <> "/coverage/result.txt", "second")
        let assert Ok("second") =
          fs.read_file(workspace <> "/coverage/result.txt")
        let assert Ok(Nil) = fs.remove_tree(workspace)
        expect(copied_config) |> to_equal(True)
        expect(copied_dependencies) |> to_equal(True)
        expect(copied_compiled_output) |> to_equal(False)
        expect(fs.is_directory(workspace)) |> to_equal(False)
      }),
      it("does not clone generated coverage, editor, or dependency trees", fn() {
        expect(fs.workspace_entry_excluded(".kangaroo-coverage-old"))
        |> to_equal(True)
        expect(fs.workspace_entry_excluded(".vscode-test")) |> to_equal(True)
        expect(fs.workspace_entry_excluded("node_modules")) |> to_equal(True)
        expect(fs.workspace_entry_excluded("build")) |> to_equal(True)
        expect(fs.workspace_entry_excluded("coverage")) |> to_equal(True)
        expect(fs.workspace_entry_excluded("src")) |> to_equal(False)
        expect(fs.workspace_entry_excluded("priv")) |> to_equal(False)
      }),
      it("instruments only the disposable coverage clone", fn() {
        let assert Ok(prepared) =
          coverage_run.prepare(".", ["test/v1/passing.gleam"], [])
        let assert [FileCoverage(path, executable, [])] = prepared.files
        let assert Ok(cloned) =
          fs.read_file(prepared.workspace <> "/test/v1/passing.gleam")
        let assert Ok(original) = fs.read_file("test/v1/passing.gleam")
        let assert Ok(Nil) = coverage_run.cleanup(prepared)
        expect(path) |> to_equal("test/v1/passing.gleam")
        expect(executable == []) |> to_equal(False)
        expect(string.contains(cloned, "kangaroo_coverage_probe.hit"))
        |> to_be_true()
        expect(string.contains(original, "kangaroo_coverage_probe.hit"))
        |> to_equal(False)
        expect(fs.is_directory(prepared.workspace)) |> to_equal(False)
      }),
      it(
        "validates exact coverage instrumentation without writing source",
        fn() {
          let assert Ok(before) = fs.read_file("src/kangaroo.gleam")
          let assert Ok(1) =
            coverage_run.validate(".", ["src/kangaroo.gleam"], [])
          let assert Ok(after) = fs.read_file("src/kangaroo.gleam")
          expect(after) |> to_equal(before)
        },
      ),
      it("plans terminal LCOV and Cobertura outputs from one result", fn() {
        let assert Ok(outputs) =
          coverage_run.outputs(files(), [
            "terminal",
            "lcov",
            "cobertura",
          ])
        let assert [
          coverage_run.TerminalOutput(terminal),
          coverage_run.FileOutput("coverage/lcov.info", lcov),
          coverage_run.FileOutput("coverage/cobertura.xml", cobertura),
        ] = outputs
        expect(string.contains(terminal, "TOTAL  33%")) |> to_be_true()
        expect(string.contains(lcov, "SF:src/a.gleam")) |> to_be_true()
        expect(string.contains(cobertura, "<coverage")) |> to_be_true()
      }),
      it(
        "uses CLI coverage reporters as a complete configuration override",
        fn() {
          expect(coverage_run.selected_reporters(["terminal"], []))
          |> to_equal(["terminal"])
          expect(
            coverage_run.selected_reporters(["terminal"], [
              "lcov",
              "lcov",
              "cobertura",
            ]),
          )
          |> to_equal(["lcov", "cobertura"])
        },
      ),
      it("uses exit one for failed tests or unmet thresholds", fn() {
        expect(coverage_run.final_exit_code(0, [])) |> to_equal(0)
        expect(coverage_run.final_exit_code(1, [])) |> to_equal(1)
        expect(coverage_run.final_exit_code(0, ["below minimum"]))
        |> to_equal(1)
        expect(coverage_run.final_exit_code(2, [])) |> to_equal(2)
      }),
    ]),
  ]
}
