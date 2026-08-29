import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/session.{CompileFinished, CompileStarted}

pub fn suites() {
  [
    suite("session", [
      it("encodes the compile phase", fn() {
        expect(session.encode(CompileStarted))
        |> to_equal("{\"type\":\"compile_started\"}")
        expect(session.encode(CompileFinished))
        |> to_equal("{\"type\":\"compile_finished\"}")
      }),
      it("round-trips the compile phase", fn() {
        expect(session.decode("{\"type\":\"compile_started\"}"))
        |> to_equal(Ok(CompileStarted))
        expect(session.decode("{\"type\":\"compile_finished\"}"))
        |> to_equal(Ok(CompileFinished))
      }),
      it("rejects other lines", fn() {
        case session.decode("{\"type\":\"run_started\"}") {
          Error(_) -> Nil
          Ok(_) -> panic as "expected a decode error"
        }
        case session.decode("not json") {
          Error(_) -> Nil
          Ok(_) -> panic as "expected a decode error"
        }
      }),
    ]),
  ]
}
