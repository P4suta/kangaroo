import gleam/option.{None, Some}
import kangaroo/internal/terminal

pub fn terminal_tui_capability_is_independent_from_colour_test() {
  assert terminal.tui_enabled(True, True) == True
  assert terminal.tui_enabled(True, False) == False
  assert terminal.tui_enabled(False, True) == False
  assert terminal.color_enabled(None, True) == True
  assert terminal.color_enabled(Some("1"), True) == False
}

pub fn terminal_dimensions_and_restore_wrapper_test() {
  assert terminal.normalise_dimensions(0, -1) == #(80, 24)
  let #(columns, rows) = terminal.dimensions()
  assert columns > 0
  assert rows > 0
  assert terminal.with_ui(fn() { 42 }) == 42
}
