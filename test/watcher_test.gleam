import gleam/dict
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
import kangaroo/internal/watcher.{Added, Modified, Removed}

pub fn suites() {
  [
    suite("watch snapshots", [
      it("detects add modify remove including identical metadata saves", fn() {
        let before =
          dict.from_list([
            #("src/changed.gleam", "old bytes"),
            #("src/removed.gleam", "gone"),
          ])
        let after =
          dict.from_list([
            #("src/added.gleam", "new"),
            #("src/changed.gleam", "new bytes"),
          ])
        expect(watcher.diff(before, after))
        |> to_equal([
          Added("src/added.gleam"),
          Modified("src/changed.gleam"),
          Removed("src/removed.gleam"),
        ])
      }),
      it("normalises rename as an add and a removal", fn() {
        expect(watcher.diff(
          dict.from_list([#("test\\old.gleam", "same")]),
          dict.from_list([#("test/new.gleam", "same")]),
        ))
        |> to_equal([
          Added("test/new.gleam"),
          Removed("test/old.gleam"),
        ])
      }),
      it("watches Gleam FFI configuration and manifest files", fn() {
        expect(watcher.is_watched("src/a.gleam")) |> to_equal(True)
        expect(watcher.is_watched("src/a.erl")) |> to_equal(True)
        expect(watcher.is_watched("src/a.mjs")) |> to_equal(True)
        expect(watcher.is_watched("gleam.toml")) |> to_equal(True)
        expect(watcher.is_watched("manifest.toml")) |> to_equal(True)
        expect(watcher.is_watched("README.md")) |> to_equal(False)
      }),
      it("builds a unique normalised watch root set", fn() {
        expect(watcher.roots(["test", "test\\integration"], ["priv", "test"]))
        |> to_equal(["src", "test", "test/integration", "priv"])
      }),
      it("uses a compile-only target-specific build command", fn() {
        expect(watcher.compile_arguments("javascript"))
        |> to_equal(["build", "--target", "javascript"])
      }),
      it("builds a target-specific cancellable child run command", fn() {
        expect(
          watcher.run_arguments("javascript", [
            "test/a.gleam::a_test",
            "--reporter",
            "dot",
          ]),
        )
        |> to_equal([
          "test",
          "--target",
          "javascript",
          "--",
          "test/a.gleam::a_test",
          "--reporter",
          "dot",
        ])
      }),
      it("preserves the active JavaScript runtime in child generations", fn() {
        expect(
          watcher.run_arguments_for("javascript", "bun", ["--tag", "unit"]),
        )
        |> to_equal([
          "test",
          "--target",
          "javascript",
          "--runtime",
          "bun",
          "--",
          "--tag",
          "unit",
        ])
        expect(watcher.run_arguments_for("erlang", "erlang", []))
        |> to_equal(["test", "--target", "erlang", "--"])
      }),
      it("starts the watch coordinator through the public run command", fn() {
        expect(
          watcher.coordinator_arguments_for("javascript", "deno", [
            "watch",
            "--tag",
            "unit",
          ]),
        )
        |> to_equal([
          "run",
          "--target",
          "javascript",
          "--runtime",
          "deno",
          "-m",
          "kangaroo",
          "--",
          "watch",
          "--tag",
          "unit",
        ])
        expect(
          watcher.coordinator_arguments_for("erlang", "erlang", [
            "watch",
          ]),
        )
        |> to_equal([
          "run",
          "--target",
          "erlang",
          "-m",
          "kangaroo",
          "--",
          "watch",
        ])
      }),
    ]),
  ]
}
