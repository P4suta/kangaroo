import gleam/option.{None, Some}
import kangaroo/format
import kangaroo/internal/terminal

pub fn color_is_enabled_only_for_a_tty_without_non_empty_no_color_test() {
  assert terminal.color_enabled(None, True)
  assert !terminal.color_enabled(None, False)
  assert terminal.color_enabled(Some(""), True)
  assert !terminal.color_enabled(Some("1"), True)
}

pub fn framework_ansi_sequences_are_removed_test() {
  assert format.without_color("\u{1b}[31mred\u{1b}[0m \u{1b}[2mdim\u{1b}[0m")
    == "red dim"
}
