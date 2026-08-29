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
