import gleam/option.{None, Some}
import kangaroo/diff.{Added, Kept, Removed, diff_lines, diff_lines_numbered}

pub fn identical_text_has_no_diff_test() {
  assert diff_lines("a\nb\nc", "a\nb\nc") == None
}

pub fn single_line_text_has_no_diff_test() {
  assert diff_lines("hello", "world") == None
}

pub fn line_diff_shows_added_lines_test() {
  assert diff_lines("a\nb", "a\nb\nc") == Some("+ c")
}

pub fn line_diff_shows_removed_lines_test() {
  assert diff_lines("a\nb\nc", "a\nc") == Some("- b")
}

pub fn line_diff_shows_replaced_lines_test() {
  assert diff_lines("a\nb\nc", "a\nx\nc") == Some("- b\n+ x")
}

pub fn line_diff_shows_multiple_changes_in_order_test() {
  assert diff_lines("a\nb\nc\nd", "a\nx\nc\ny") == Some("- b\n+ x\n- d\n+ y")
}

pub fn two_empty_texts_have_no_diff_test() {
  assert diff_lines("", "") == None
}

pub fn empty_and_single_line_text_have_no_diff_test() {
  assert diff_lines("", "a") == None
}

pub fn bare_newlines_have_no_diff_test() {
  assert diff_lines("\n", "\n") == None
}

pub fn numbered_diff_numbers_replaced_lines_test() {
  assert diff_lines_numbered("a\nb\nc", "a\nx\nc")
    == Some([
      Kept(1, "a"),
      Removed(2, "b"),
      Added(2, "x"),
      Kept(3, "c"),
    ])
}

pub fn numbered_diff_numbers_added_lines_from_actual_text_test() {
  assert diff_lines_numbered("a\nb", "a\nb\nc")
    == Some([Kept(1, "a"), Kept(2, "b"), Added(3, "c")])
}

pub fn numbered_diff_numbers_removed_lines_from_expected_text_test() {
  assert diff_lines_numbered("a\nb\nc", "a\nc")
    == Some([Kept(1, "a"), Removed(2, "b"), Kept(3, "c")])
}

pub fn identical_text_has_no_numbered_diff_test() {
  assert diff_lines_numbered("a\nb", "a\nb") == None
}
