import kangaroo/internal/glob
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

pub fn suites() {
  [
    suite("glob", [
      it("matches star and question only inside one path segment", fn() {
        expect(glob.matches("test/*_test.gleam", "test/math_test.gleam"))
        |> to_equal(True)
        expect(glob.matches("test/?_test.gleam", "test/a_test.gleam"))
        |> to_equal(True)
        expect(glob.matches("test/*_test.gleam", "test/unit/a_test.gleam"))
        |> to_equal(False)
      }),
      it("matches globstar across zero or more path segments", fn() {
        expect(glob.matches("src/**/*.gleam", "src/app.gleam"))
        |> to_equal(True)
        expect(glob.matches("src/**/*.gleam", "src/app/http.gleam"))
        |> to_equal(True)
        expect(glob.matches("test/generated/**", "test/generated/a/b.gleam"))
        |> to_equal(True)
      }),
      it("normalises windows separators", fn() {
        expect(glob.matches("test/**/*.gleam", "test\\unit\\math.gleam"))
        |> to_equal(True)
      }),
    ]),
  ]
}
