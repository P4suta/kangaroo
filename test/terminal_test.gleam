import gleam/option.{None, Some}
import kangaroo/format
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
import kangaroo/internal/terminal

pub fn suites() {
  [
    suite("terminal capabilities", [
      it("uses colour only for a TTY without NO_COLOR", fn() {
        expect(terminal.color_enabled(None, True)) |> to_equal(True)
        expect(terminal.color_enabled(None, False)) |> to_equal(False)
        expect(terminal.color_enabled(Some(""), True)) |> to_equal(False)
        expect(terminal.color_enabled(Some("1"), True)) |> to_equal(False)
      }),
      it("removes every framework ANSI sequence", fn() {
        expect(format.without_color(
          "\u{1b}[31mred\u{1b}[0m \u{1b}[2mdim\u{1b}[0m",
        ))
        |> to_equal("red dim")
      }),
    ]),
  ]
}
