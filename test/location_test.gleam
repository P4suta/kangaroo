import gleam/option.{None, Some}
import kangaroo/failure.{
  AssertionFailed, EqualityMismatch, UnexpectedError, attach,
}
import kangaroo/location.{
  Location, from_erlang_stack, from_js_stack, is_framework_file,
}

pub fn framework_files_are_classified_test() {
  assert is_framework_file("src/kangaroo/internal/executor.gleam")
  assert is_framework_file("src/kangaroo_isolate_ffi.erl")
  assert is_framework_file("src/gleam/list.gleam")
  assert is_framework_file("gleam/list.gleam")
  assert is_framework_file("node:internal/process/task_queues:7")
  assert is_framework_file("src/kangaroo/kangaroo/internal/executor.mjs")
  assert is_framework_file("build/dev/javascript/gleam_stdlib/gleam.mjs")
  assert !is_framework_file("test/foo_test.gleam")
  assert !is_framework_file("src/myapp/calculator.gleam")
  assert !is_framework_file("/home/u/proj/runtime_test.mjs")
}

pub fn compiled_framework_artefacts_are_classified_test() {
  // Framework modules can appear as generated artefact paths when the
  // project's tests execute in the CLI VM.
  assert is_framework_file(
    "/home/u/proj/build/dev/erlang/kangaroo/_gleam_artefacts/kangaroo@internal@executor.erl",
  )
  assert is_framework_file(
    "/home/u/proj/cli/build/dev/erlang/kangaroo/_gleam_artefacts/kangaroo@isolate.erl",
  )
  assert is_framework_file(
    "/home/u/proj/build/dev/erlang/kangaroo/_gleam_artefacts/kangaroo_location_ffi.erl",
  )
  assert is_framework_file(
    "/home/u/proj/cli/build/dev/erlang/kangaroo_cli/_gleam_artefacts/kangaroo_cli@app.erl",
  )
  assert !is_framework_file(
    "/home/u/proj/build/dev/erlang/myapp/_gleam_artefacts/myapp@thing.erl",
  )
}

pub fn checkout_directory_name_is_not_mistaken_for_framework_test() {
  assert !is_framework_file(
    "/home/runner/work/kangaroo/kangaroo/build/dev/javascript/kangaroo/internal/executor_test.mjs",
  )
  assert is_framework_file(
    "/home/runner/work/kangaroo/kangaroo/build/dev/javascript/kangaroo/kangaroo/internal/executor.mjs",
  )
}

pub fn windows_stack_paths_are_normalised_before_classification_test() {
  assert !is_framework_file("test\\runtime_fixture.gleam")
  assert is_framework_file("src\\kangaroo\\isolate.gleam")
  assert from_erlang_stack("test\\runtime_fixture.gleam:33")
    == Some(Location("test/runtime_fixture.gleam", 33, None))
}

pub fn absolute_framework_paths_are_filtered_on_all_platforms_test() {
  assert is_framework_file("/work/project/src/kangaroo/isolate.gleam")
  assert is_framework_file("C:\\work\\project\\src\\kangaroo.gleam")
  assert from_erlang_stack(
      "C:\\work\\project\\src\\kangaroo\\isolate.gleam:20\n"
      <> "C:\\work\\project\\test\\user_test.gleam:7",
    )
    == Some(Location("C:/work/project/test/user_test.gleam", 7, None))
}

pub fn compiled_artefacts_are_skipped_when_selecting_a_user_frame_test() {
  let stack =
    "/home/u/proj/cli/build/dev/erlang/kangaroo/_gleam_artefacts/kangaroo_location_ffi.erl:8\n"
    <> "/home/u/proj/cli/build/dev/erlang/kangaroo/_gleam_artefacts/kangaroo@internal@executor.erl:11\n"
    <> "test/foo_test.gleam:42"
  assert from_erlang_stack(stack)
    == Some(Location("test/foo_test.gleam", 42, None))
}

pub fn first_erlang_user_frame_is_selected_test() {
  let stack =
    "src/kangaroo/internal/executor.gleam:32\n"
    <> "src/kangaroo_isolate_ffi.erl:11\n"
    <> "test/foo_test.gleam:42"
  assert from_erlang_stack(stack)
    == Some(Location("test/foo_test.gleam", 42, None))
}

pub fn empty_erlang_stack_has_no_location_test() {
  assert from_erlang_stack("") == None
}

pub fn all_framework_erlang_stack_has_no_location_test() {
  assert from_erlang_stack("src/kangaroo/internal/executor.gleam:3") == None
}

pub fn stack_lines_without_line_numbers_are_ignored_test() {
  let stack = "not a location\n" <> "test/foo_test.gleam:7"
  assert from_erlang_stack(stack)
    == Some(Location("test/foo_test.gleam", 7, None))
}

pub fn v8_file_url_stack_with_columns_is_parsed_test() {
  let stack =
    "Error: expected True\n"
    <> "    at runResolved (file:///home/u/proj/build/dev/javascript/kangaroo/kangaroo/internal/executor.mjs:18:5)\n"
    <> "    at main (file:///home/u/proj/build/dev/javascript/kangaroo/runtime_test.mjs:12:7)"
  assert from_js_stack(stack)
    == Some(Location(
      "/home/u/proj/build/dev/javascript/kangaroo/runtime_test.mjs",
      12,
      Some(7),
    ))
}

pub fn v8_stack_without_parentheses_is_parsed_test() {
  let stack =
    "Error: boom\n"
    <> "    at file:///home/u/proj/build/dev/javascript/myapp/foo_test.mjs:3:1"
  assert from_js_stack(stack)
    == Some(Location(
      "/home/u/proj/build/dev/javascript/myapp/foo_test.mjs",
      3,
      Some(1),
    ))
}

pub fn erlang_stack_column_is_parsed_test() {
  let stack =
    "src/kangaroo/internal/executor.gleam:32:5\n" <> "test/foo_test.gleam:42:9"
  assert from_erlang_stack(stack)
    == Some(Location("test/foo_test.gleam", 42, Some(9)))
}

pub fn node_internal_v8_frames_are_skipped_test() {
  let stack =
    "Error: boom\n" <> "    at node:internal/main/run_main_module:12:1"
  assert from_js_stack(stack) == None
}

pub fn location_attaches_to_equality_mismatch_test() {
  let location = Location("test/foo_test.gleam", 5, None)
  let assert EqualityMismatch(_, _, _, Some(got)) =
    attach(EqualityMismatch("a", "b", None, None), location)
  assert got.file == "test/foo_test.gleam"
  assert got.line == 5
}

pub fn location_attaches_to_assertion_failure_test() {
  let location = Location("test/foo_test.gleam", 5, None)
  let assert AssertionFailed(_, Some(got)) =
    attach(AssertionFailed("boom", None), location)
  assert got == location
}

pub fn location_attaches_to_unexpected_error_test() {
  let location = Location("test/foo_test.gleam", 5, None)
  let assert UnexpectedError(_, _, Some(got)) =
    attach(UnexpectedError("panic", "boom", None), location)
  assert got == location
}
