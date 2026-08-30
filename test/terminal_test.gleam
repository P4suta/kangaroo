import gleam/option.{None, Some}
import gleam/string
import kangaroo/format
import kangaroo/internal/fs
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

pub fn erlang_suspend_relinquishes_stdin_before_an_interactive_child_test() {
  let assert Ok(source) = fs.read_file("src/kangaroo_terminal_ffi.erl")
  let assert [_, suspend_source] = string.split(source, "suspend(Body) ->")
  let assert [suspend_source, _] =
    string.split(suspend_source, "raw_mode(true) ->")

  let assert [before_restore, after_restore] =
    string.split(suspend_source, "raw_mode(false)")
  assert string.contains(before_restore, "stop_keyboard_reader()")
  assert string.contains(after_restore, "start_keyboard_reader()")
}
