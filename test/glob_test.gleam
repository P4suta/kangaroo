import gleam/string
import kangaroo/internal/glob

pub fn star_and_question_match_only_one_path_segment_test() {
  assert glob.matches("test/*_test.gleam", "test/math_test.gleam")
  assert glob.matches("test/?_test.gleam", "test/a_test.gleam")
  assert !glob.matches("test/*_test.gleam", "test/unit/a_test.gleam")
}

pub fn globstar_matches_zero_or_more_path_segments_test() {
  assert glob.matches("src/**/*.gleam", "src/app.gleam")
  assert glob.matches("src/**/*.gleam", "src/app/http.gleam")
  assert glob.matches("test/generated/**", "test/generated/a/b.gleam")
}

pub fn glob_normalises_windows_separators_test() {
  assert glob.matches("test/**/*.gleam", "test\\unit\\math.gleam")
}

pub fn adversarial_wildcards_have_bounded_matching_test() {
  let segment_pattern = string.repeat("*a", 80) <> "b"
  let segment_value = string.repeat("a", 80)
  assert !glob.matches("test/" <> segment_pattern, "test/" <> segment_value)

  let globstar_pattern = string.repeat("**/", 40) <> "missing.gleam"
  let nested_path = string.repeat("directory/", 40) <> "present.gleam"
  assert !glob.matches(globstar_pattern, nested_path)
}
