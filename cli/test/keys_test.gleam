import gleam/option.{None, Some}
import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/keys.{Nothing, Quit, Rerun, ToggleView, action, toggle_view}
import kangaroo_cli/tui.{All, FailuresOnly}

pub fn suites() {
  [
    suite("keys", [
      it("maps r to a full re-run", fn() {
        expect(action(Some("r"))) |> to_equal(Rerun)
      }),
      it("maps f to the view toggle", fn() {
        expect(action(Some("f"))) |> to_equal(ToggleView)
      }),
      it("maps q to quit", fn() {
        expect(action(Some("q"))) |> to_equal(Quit)
      }),
      it("maps Ctrl+C to quit", fn() {
        expect(action(Some("\u{3}"))) |> to_equal(Quit)
      }),
      it("ignores unknown keys", fn() {
        expect(action(Some("x"))) |> to_equal(Nothing)
        expect(action(Some(""))) |> to_equal(Nothing)
      }),
      it("ignores the absence of a key", fn() {
        expect(action(None)) |> to_equal(Nothing)
      }),
      it("toggles the view both ways", fn() {
        expect(toggle_view(All)) |> to_equal(FailuresOnly)
        expect(toggle_view(FailuresOnly)) |> to_equal(All)
      }),
    ]),
  ]
}
