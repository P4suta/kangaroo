import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/coverage.{
  ModuleCoverage, line_count, percentage, summarise, table_row,
}

pub fn suites() {
  [
    suite("coverage", [
      it("summarises line hits within the file", fn() {
        let result =
          summarise("diff", 10, [
            #(1, 5),
            #(2, 0),
            #(3, 1),
            #(11, 9),
          ])
        expect(result)
        |> to_equal(ModuleCoverage("diff", 2, 3))
      }),
      it("computes the total percentage", fn() {
        let modules = [
          ModuleCoverage("a", 2, 4),
          ModuleCoverage("b", 1, 1),
        ]
        expect(percentage(modules)) |> to_equal(60)
      }),
      it("treats an empty module as fully covered", fn() {
        expect(percentage([ModuleCoverage("a", 0, 0)])) |> to_equal(100)
      }),
      it("renders table rows", fn() {
        expect(table_row(ModuleCoverage("a", 2, 4)))
        |> to_equal("a  50% (2/4 lines)")
      }),
      it("counts lines in a source file", fn() {
        expect(line_count("a\nb\nc")) |> to_equal(3)
        expect(line_count("")) |> to_equal(0)
      }),
    ]),
  ]
}
