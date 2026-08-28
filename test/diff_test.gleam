import gleam/option.{None, Some}
import kangaroo/diff
import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}

pub fn suites() {
  [
    suite("diff", [
      it("returns no diff for identical texts", fn() {
        expect(diff.diff_lines("a\nb\nc", "a\nb\nc")) |> to_equal(None)
      }),
      it("returns no diff for single lines", fn() {
        expect(diff.diff_lines("hello", "world")) |> to_equal(None)
      }),
      it("shows added lines", fn() {
        expect(diff.diff_lines("a\nb", "a\nb\nc")) |> to_equal(Some("+ c"))
      }),
      it("shows removed lines", fn() {
        expect(diff.diff_lines("a\nb\nc", "a\nc")) |> to_equal(Some("- b"))
      }),
      it("shows replaced lines", fn() {
        expect(diff.diff_lines("a\nb\nc", "a\nx\nc"))
        |> to_equal(Some("- b\n+ x"))
      }),
      it("shows multiple changes in order", fn() {
        expect(diff.diff_lines("a\nb\nc\nd", "a\nx\nc\ny"))
        |> to_equal(Some("- b\n+ x\n- d\n+ y"))
      }),
      it("returns no diff for two empty texts", fn() {
        expect(diff.diff_lines("", "")) |> to_equal(None)
      }),
      it("returns no diff for empty vs single line", fn() {
        expect(diff.diff_lines("", "a")) |> to_equal(None)
      }),
      it("returns no diff for bare newlines", fn() {
        expect(diff.diff_lines("\n", "\n")) |> to_equal(None)
      }),
    ]),
  ]
}
