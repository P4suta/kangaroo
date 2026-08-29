import gleam/option.{None, Some}
import kangaroo/suite.{it, suite}
import kangaroo/expect.{expect, to_be_false, to_be_true, to_equal}
import kangaroo/failure.{AssertionFailed, EqualityMismatch, UnexpectedError, attach}
import kangaroo/location.{
  Location, from_erlang_stack, from_js_stack, is_framework_file,
}

pub fn suites() {
  [
    suite("location", [
      it("flags framework files", fn() {
        expect(is_framework_file("src/kangaroo/expect.gleam")) |> to_be_true()
        expect(is_framework_file("src/kangaroo_isolate_ffi.erl"))
        |> to_be_true()
        expect(is_framework_file("src/gleam/list.gleam")) |> to_be_true()
        expect(is_framework_file("gleam/list.gleam")) |> to_be_true()
        expect(is_framework_file("node:internal/process/task_queues:7"))
        |> to_be_true()
        expect(is_framework_file("src/kangaroo/kangaroo/expect.mjs"))
        |> to_be_true()
        expect(is_framework_file("build/dev/javascript/gleam_stdlib/gleam.mjs"))
        |> to_be_true()
        expect(is_framework_file("test/foo_test.gleam")) |> to_be_false()
        expect(is_framework_file("src/myapp/calculator.gleam"))
        |> to_be_false()
        expect(is_framework_file("/home/u/proj/runner_test.mjs"))
        |> to_be_false()
      }),
      it("picks the first user frame from an erlang stack", fn() {
        let stack =
          "src/kangaroo/expect.gleam:32\n"
          <> "src/kangaroo_isolate_ffi.erl:11\n"
          <> "test/foo_test.gleam:42"
        expect(from_erlang_stack(stack))
        |> to_equal(Some(Location("test/foo_test.gleam", 42)))
      }),
      it("returns none for an empty erlang stack", fn() {
        expect(from_erlang_stack("")) |> to_equal(None)
      }),
      it("returns none when every erlang frame is framework code",
        fn() {
          expect(from_erlang_stack("src/kangaroo/expect.gleam:3"))
          |> to_equal(None)
        },
      ),
      it("ignores lines without a line number", fn() {
        let stack = "not a location\n" <> "test/foo_test.gleam:7"
        expect(from_erlang_stack(stack))
        |> to_equal(Some(Location("test/foo_test.gleam", 7)))
      }),
      it("parses a v8 stack with file:// and columns", fn() {
        let stack =
          "Error: expected True\n"
          <> "    at toBeTrue (file:///home/u/proj/build/dev/javascript/kangaroo/kangaroo/expect.mjs:18:5)\n"
          <> "    at main (file:///home/u/proj/build/dev/javascript/kangaroo/runner_test.mjs:12:7)"
        expect(from_js_stack(stack))
        |> to_equal(Some(Location(
          "/home/u/proj/build/dev/javascript/kangaroo/runner_test.mjs",
          12,
        )))
      }),
      it("parses a v8 stack without parens", fn() {
        let stack =
          "Error: boom\n"
          <> "    at file:///home/u/proj/build/dev/javascript/myapp/foo_test.mjs:3:1"
        expect(from_js_stack(stack))
        |> to_equal(Some(Location(
          "/home/u/proj/build/dev/javascript/myapp/foo_test.mjs",
          3,
        )))
      }),
      it("skips node internals in v8 stacks", fn() {
        let stack =
          "Error: boom\n"
          <> "    at node:internal/main/run_main_module:12:1"
        expect(from_js_stack(stack)) |> to_equal(None)
      }),
      it("attaches a location to an equality mismatch", fn() {
        let location = Location("test/foo_test.gleam", 5)
        case attach(EqualityMismatch("a", "b", None, None), location) {
          EqualityMismatch(_, _, _, Some(got)) -> {
            expect(got.file) |> to_equal("test/foo_test.gleam")
            expect(got.line) |> to_equal(5)
          }
          _ -> panic as "expected equality mismatch with location"
        }
      }),
      it("attaches a location to an assertion failure", fn() {
        let location = Location("test/foo_test.gleam", 5)
        case attach(AssertionFailed("boom", None), location) {
          AssertionFailed(_, Some(got)) -> expect(got) |> to_equal(location)
          _ -> panic as "expected assertion failure with location"
        }
      }),
      it("attaches a location to an unexpected error", fn() {
        let location = Location("test/foo_test.gleam", 5)
        case attach(UnexpectedError("panic", "boom", None), location) {
          UnexpectedError(_, _, Some(got)) -> expect(got) |> to_equal(location)
          _ -> panic as "expected unexpected error with location"
        }
      }),
    ]),
  ]
}
