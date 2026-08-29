import gleam/option.{None, Some}
import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/coverage.{ModuleCoverage}
import kangaroo_cli/jscoverage.{
  Script, covered_lines, decode_coverage, in_project, line_starts, local_path,
  module_from_url, summarise,
}

pub fn suites() {
  [
    suite("jscoverage", [
      it("decodes a V8 coverage document", fn() {
        let contents =
          "{\"result\":[{\"url\":\"file:///x/build/dev/javascript/pkg/foo.mjs\",\"functions\":[{\"functionName\":\"f\",\"ranges\":[{\"startOffset\":0,\"endOffset\":10,\"count\":1}]}]}]}"
        let result = decode_coverage(contents)
        expect(result)
        |> to_equal(
          Ok([
            Script("file:///x/build/dev/javascript/pkg/foo.mjs", [#(0, 10, 1)]),
          ]),
        )
      }),
      it("flattens ranges across functions", fn() {
        let contents =
          "{\"result\":[{\"url\":\"file:///x/build/dev/javascript/pkg/foo.mjs\",\"functions\":[{\"ranges\":[{\"startOffset\":0,\"endOffset\":5,\"count\":1}]},{\"ranges\":[{\"startOffset\":9,\"endOffset\":12,\"count\":0}]}]}]}"
        let result = decode_coverage(contents)
        expect(result)
        |> to_equal(
          Ok([
            Script("file:///x/build/dev/javascript/pkg/foo.mjs", [
              #(0, 5, 1),
              #(9, 12, 0),
            ]),
          ]),
        )
      }),
      it("rejects malformed documents", fn() {
        let result = decode_coverage("not json")
        case result {
          Error(_) -> expect(True) |> to_equal(True)
          Ok(_) -> expect(False) |> to_equal(True)
        }
      }),
      it("computes line start offsets", fn() {
        expect(line_starts("a\nbb\nc")) |> to_equal([0, 2, 5])
        expect(line_starts("")) |> to_equal([0])
        expect(line_starts("single")) |> to_equal([0])
      }),
      it("finds lines covered by counted ranges", fn() {
        // line 1 covers offsets 0-1, line 2 starts at 2, line 3 at 5
        let ranges = [#(0, 2, 1), #(5, 6, 1)]
        expect(covered_lines("a\nbb\nc", ranges)) |> to_equal([1, 3])
      }),
      it("ignores uncounted ranges", fn() {
        let ranges = [#(0, 6, 0)]
        expect(covered_lines("a\nbb\nc", ranges)) |> to_equal([])
      }),
      it("derives module names from script URLs", fn() {
        expect(module_from_url(
          "file:///x/build/dev/javascript/pkg/kangaroo/diff.mjs",
        ))
        |> to_equal(Some("pkg/kangaroo/diff"))
        expect(module_from_url("file:///x/build/dev/javascript/pkg/foo.mjs"))
        |> to_equal(Some("pkg/foo"))
      }),
      it("ignores scripts outside the build output", fn() {
        expect(module_from_url("file:///x/node_modules/thing.mjs"))
        |> to_equal(None)
        expect(module_from_url("node:internal/modules"))
        |> to_equal(None)
      }),
      it("detects scripts inside the project's build output", fn() {
        expect(in_project("file:///x/build/dev/javascript/pkg/foo.mjs", "pkg"))
        |> to_equal(True)
        expect(in_project(
          "file:///x/build/dev/javascript/gleam_stdlib/gleam.mjs",
          "pkg",
        ))
        |> to_equal(False)
        expect(in_project("node:internal/x", "pkg")) |> to_equal(False)
      }),
      it("turns script URLs into local paths", fn() {
        expect(local_path("file:///x/build/dev/javascript/pkg/foo.mjs"))
        |> to_equal("/x/build/dev/javascript/pkg/foo.mjs")
        expect(local_path("/plain/path.mjs")) |> to_equal("/plain/path.mjs")
      }),
      it("summarises a module", fn() {
        let ranges = [#(0, 2, 1)]
        expect(summarise("pkg/foo", "a\nbb\nc", ranges))
        |> to_equal(ModuleCoverage("pkg/foo", 1, 3))
      }),
    ]),
  ]
}
