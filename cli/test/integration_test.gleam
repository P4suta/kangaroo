import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/app

pub fn suites() {
  [
    suite("integration", [
      it("runs the parent project's tests and finds them passing", fn() {
        // The CLI package's tests run from cli/, so the parent directory is
        // the kangaroo package itself. This exercises the real executor:
        // spawning `gleam test`, capturing its output, and parsing events.
        let result = app.run_once("..")
        expect(result) |> to_equal(Ok(False))
      }),
    ]),
  ]
}

