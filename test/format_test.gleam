import gleam/option.{None, Some}
import gleam/string
import kangaroo/expect.{expect, to_be_true, to_equal}
import kangaroo/format
import kangaroo/location.{Location}
import kangaroo/suite.{it, suite}

pub fn suites() {
  [
    suite("format", [
      it("renders a colored numbered diff", fn() {
        let rendered = format.render_diff("a\nb\nc", "a\nx\nc")
        string.contains(rendered, "\u{1b}[31m") |> expect |> to_be_true()
        string.contains(rendered, "\u{1b}[32m") |> expect |> to_be_true()
        string.contains(rendered, "-2 b") |> expect |> to_be_true()
        string.contains(rendered, "+2 x") |> expect |> to_be_true()
        string.contains(rendered, "1 a") |> expect |> to_be_true()
      }),
      it("renders nothing for identical texts", fn() {
        expect(format.render_diff("a\nb", "a\nb")) |> to_equal("")
      }),
      it("shows no diff section for single lines", fn() {
        expect(format.render_diff("x", "y")) |> to_equal("")
      }),
      it("renders a location line", fn() {
        let rendered =
          format.location_line(Some(Location("test/foo_test.gleam", 7, None)))
        string.contains(rendered, "at test/foo_test.gleam:7")
        |> expect
        |> to_be_true()
      }),
      it("renders no location line when unknown", fn() {
        expect(format.location_line(None)) |> to_equal("")
      }),
    ]),
  ]
}
