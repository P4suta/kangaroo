import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import kangaroo/event.{
  type Event, CaseFinished, CaseOutput, RunFinished, RunStarted,
}
import kangaroo/failure.{
  type Failure, type Outcome, AssertionFailed, EqualityMismatch, Failed, Flaky,
  Passed, Skipped, SkippedWithReason, UnexpectedError,
}
import kangaroo/internal/reporter_buffer
import kangaroo/report.{type CaseResult, type Report, CaseResult, Report}

pub fn dot_sink(event: Event) -> Nil {
  case event {
    RunStarted(..) -> Nil
    CaseFinished(_, _, outcome, _) -> io.print(dot(outcome))
    RunFinished(_, summary) ->
      io.println(
        "  "
        <> int.to_string(summary.passed)
        <> " passed, "
        <> int.to_string(summary.failed)
        <> " failed, "
        <> int.to_string(summary.skipped)
        <> " skipped",
      )
    _ -> Nil
  }
}

pub fn junit_sink(event: Event) -> Nil {
  case event {
    RunStarted(..) -> {
      reporter_buffer.take()
      reporter_buffer.take_output()
      Nil
    }
    CaseFinished(suite, name, outcome, duration_ms) ->
      reporter_buffer.append(CaseResult(suite, name, outcome, duration_ms))
    CaseOutput(_, name, stdout, stderr, _) ->
      reporter_buffer.append_output(name, stdout, stderr)
    RunFinished(_, summary) -> {
      let report = Report(reporter_buffer.take(), [])
      let output =
        reporter_buffer.take_output()
        |> list.map(fn(capture) { CaseCapture(capture.0, capture.1, capture.2) })
      io.print(junit_with_output(report, output, summary.duration_ms))
    }
    _ -> Nil
  }
}

pub fn dot(outcome: Outcome) -> String {
  case outcome {
    Passed -> "."
    Failed(_) -> "F"
    Flaky(_, _) -> "R"
    Skipped -> "S"
    SkippedWithReason(_) -> "S"
  }
}

pub fn id_parts(id: String) -> #(String, String) {
  case string.split(id, "::") {
    [path, name] -> #(path, name)
    _ -> #("", id)
  }
}

pub type CaseCapture {
  CaseCapture(case_name: String, stdout: String, stderr: String)
}

/// Renders a complete JUnit XML document from the same report used by the
/// terminal and protocol reporters.
pub fn junit(report: Report, duration_ms: Int) -> String {
  junit_with_output(report, [], duration_ms)
}

pub fn junit_with_output(
  report: Report,
  output: List(CaseCapture),
  duration_ms: Int,
) -> String {
  let #(failures, skipped) =
    list.fold(report.cases, #(0, 0), fn(counts, case_result) {
      case case_result.outcome {
        Failed(_) -> #(counts.0 + 1, counts.1)
        Flaky(_, _) -> #(counts.0 + 1, counts.1)
        Skipped -> #(counts.0, counts.1 + 1)
        SkippedWithReason(_) -> #(counts.0, counts.1 + 1)
        Passed -> counts
      }
    })
  let header =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    <> "<testsuite name=\"kangaroo\" tests=\""
    <> int.to_string(list.length(report.cases))
    <> "\" failures=\""
    <> int.to_string(failures)
    <> "\" skipped=\""
    <> int.to_string(skipped)
    <> "\" time=\""
    <> seconds(duration_ms)
    <> "\">\n"
  let cases =
    report.cases
    |> list.map(fn(case_result) { junit_case(case_result, output) })
    |> string.join("\n")
  header <> cases <> "\n</testsuite>\n"
}

fn junit_case(case_result: CaseResult, output: List(CaseCapture)) -> String {
  let #(path, name) = id_parts(case_result.case_name)
  let start =
    "  <testcase classname=\""
    <> xml(case_result.suite)
    <> "\" name=\""
    <> xml(name)
    <> "\" file=\""
    <> xml(path)
    <> "\" time=\""
    <> seconds(case_result.duration_ms)
    <> "\""
  let outcome = case case_result.outcome {
    Passed -> ""
    Skipped -> "<skipped/>"
    SkippedWithReason(reason) -> "<skipped message=\"" <> xml(reason) <> "\"/>"
    Flaky(failures, attempts) -> {
      let details = failures |> list.map(failure_text) |> string.join("; ")
      let message =
        "flaky after " <> int.to_string(attempts) <> " attempts: " <> details
      "<failure type=\"flaky\" message=\""
      <> xml(message)
      <> "\">"
      <> xml(message)
      <> "</failure>"
    }
    Failed(failures) -> {
      let message = failures |> list.map(failure_text) |> string.join("\n")
      "<failure message=\""
      <> xml(message)
      <> "\">"
      <> xml(message)
      <> "</failure>"
    }
  }
  let contents = outcome <> capture_xml(case_result.case_name, output)
  case contents {
    "" -> start <> "/>"
    _ -> start <> ">" <> contents <> "</testcase>"
  }
}

fn capture_xml(case_name: String, output: List(CaseCapture)) -> String {
  case output {
    [] -> ""
    [CaseCapture(name, stdout, stderr), ..] if name == case_name ->
      stream_xml("system-out", stdout) <> stream_xml("system-err", stderr)
    [_, ..rest] -> capture_xml(case_name, rest)
  }
}

fn stream_xml(element: String, contents: String) -> String {
  case contents {
    "" -> ""
    _ -> "<" <> element <> ">" <> xml(contents) <> "</" <> element <> ">"
  }
}

fn failure_text(failure: Failure) -> String {
  case failure {
    UnexpectedError(name, message, _) -> name <> ": " <> message
    AssertionFailed(message, _) -> message
    EqualityMismatch(expected, actual, _, _) ->
      "expected " <> expected <> ", got " <> actual
  }
}

fn seconds(milliseconds: Int) -> String {
  milliseconds
  |> int.to_float
  |> fn(value) { value /. 1000.0 }
  |> float.to_string
}

fn xml(value: String) -> String {
  value
  |> string.replace(each: "&", with: "&amp;")
  |> string.replace(each: "<", with: "&lt;")
  |> string.replace(each: ">", with: "&gt;")
  |> string.replace(each: "\"", with: "&quot;")
  |> string.replace(each: "'", with: "&apos;")
}
