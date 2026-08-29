import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/command.{
  Coverage, Daemon, Doctor, Dot, Help, Init, Junit, ListTests, Ndjson, Pretty,
  Run, RunOptions, Version, Watch,
}
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

pub fn suites() {
  [
    suite("commands", [
      it("uses one-shot execution when no command is supplied", fn() {
        expect(command.parse([]))
        |> to_equal(Ok(Run(command.default_run_options())))
      }),
      it("accepts direct selectors for cancellable watch child runs", fn() {
        expect(
          command.parse([
            "test/app_test.gleam::addition_test",
            "--reporter=ndjson",
          ]),
        )
        |> to_equal(
          Ok(Run(
            RunOptions(
              ..command.default_run_options(),
              selectors: ["test/app_test.gleam::addition_test"],
              reporter: Ndjson,
            ),
          )),
        )
      }),
      it("parses watch selectors tags and reporter overrides", fn() {
        expect(
          command.parse([
            "watch",
            "test/a_test.gleam:9",
            "--tag",
            "unit",
            "--exclude-tag=slow",
            "--reporter",
            "dot",
            "--fail-fast",
          ]),
        )
        |> to_equal(
          Ok(
            Watch(
              RunOptions(
                selectors: ["test/a_test.gleam:9"],
                include_tags: ["unit"],
                exclude_tags: ["slow"],
                reporter: Dot,
                fail_fast: True,
                workers: None,
                timeout_ms: None,
                retry: None,
                shuffle: None,
                coverage_reporters: [],
              ),
            ),
          ),
        )
      }),
      it("encodes a watch child run without losing CLI overrides", fn() {
        let options =
          RunOptions(
            selectors: ["ignored"],
            include_tags: ["unit"],
            exclude_tags: ["slow"],
            reporter: Dot,
            fail_fast: True,
            workers: Some(2),
            timeout_ms: Some(250),
            retry: Some(1),
            shuffle: Some(False),
            coverage_reporters: [],
          )
        expect(command.run_arguments(options, ["test/a.gleam::a_test"]))
        |> to_equal([
          "test/a.gleam::a_test",
          "--tag",
          "unit",
          "--exclude-tag",
          "slow",
          "--reporter",
          "dot",
          "--fail-fast",
          "--workers",
          "2",
          "--timeout",
          "250",
          "--retry",
          "1",
          "--no-shuffle",
        ])
      }),
      it("parses every v1 command and reporter", fn() {
        expect(command.parse(["coverage"]))
        |> to_equal(Ok(Coverage(command.default_run_options())))
        expect(command.parse(["list", "--reporter=ndjson"]))
        |> to_equal(
          Ok(ListTests(
            RunOptions(..command.default_run_options(), reporter: Ndjson),
          )),
        )
        expect(command.parse(["init"])) |> to_equal(Ok(Init))
        expect(command.parse(["doctor"])) |> to_equal(Ok(Doctor(Pretty)))
        expect(command.parse(["doctor", "--reporter=junit"]))
        |> to_equal(Ok(Doctor(Junit)))
        expect(command.parse(["daemon"])) |> to_equal(Ok(Daemon))
        expect(command.parse(["--help"])) |> to_equal(Ok(Help))
        expect(command.parse(["--version"])) |> to_equal(Ok(Version))
      }),
      it("lets coverage reporters override the configured output", fn() {
        let assert Ok(Coverage(options)) =
          command.parse([
            "coverage",
            "--coverage-reporter=lcov",
            "--coverage-reporter",
            "cobertura",
          ])
        expect(options.coverage_reporters) |> to_equal(["lcov", "cobertura"])
      }),
      it("rejects missing values invalid numbers and unknown flags", fn() {
        expect(command.parse(["watch", "--tag"]))
        |> to_equal(Error("kangaroo: --tag requires a value"))
        expect(command.parse(["watch", "--workers", "0"]))
        |> to_equal(Error("kangaroo: --workers must be a positive integer"))
        expect(command.parse(["coverage", "--coverage-reporter", "html"]))
        |> to_equal(Error(
          "kangaroo: --coverage-reporter must be terminal, lcov, or cobertura",
        ))
        case command.parse(["watch", "--wat"]) {
          Error(message) -> expect(message == "") |> to_equal(False)
          _ -> panic as "expected an unknown flag error"
        }
      }),
      it("documents only the unified kangaroo module command", fn() {
        expect(command.usage() |> string_contains("gleam run -m kangaroo"))
        |> to_be_true()
      }),
    ]),
  ]
}

fn string_contains(text: String, needle: String) -> Bool {
  string.contains(text, needle)
}
