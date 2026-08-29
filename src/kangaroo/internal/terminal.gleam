import gleam/option.{type Option, None, Some}
import kangaroo/sys

/// Colour is an output capability, not merely a reporter preference.
pub fn color_enabled(no_color: Option(String), is_terminal: Bool) -> Bool {
  case no_color, is_terminal {
    None, True -> True
    Some(_), _ | _, False -> False
  }
}

pub fn use_color() -> Bool {
  color_enabled(sys.env("NO_COLOR"), stdout_is_terminal())
}

pub fn tui_enabled(interactive: Bool, pretty_reporter: Bool) -> Bool {
  interactive && pretty_reporter
}

pub fn normalise_dimensions(columns: Int, rows: Int) -> #(Int, Int) {
  #(
    case columns > 0 {
      True -> columns
      False -> 80
    },
    case rows > 0 {
      True -> rows
      False -> 24
    },
  )
}

@external(erlang, "kangaroo_terminal_ffi", "stdout_is_terminal")
@external(javascript, "../../kangaroo_terminal_ffi.mjs", "stdout_is_terminal")
pub fn stdout_is_terminal() -> Bool

@external(erlang, "kangaroo_terminal_ffi", "interactive_terminal")
@external(javascript, "../../kangaroo_terminal_ffi.mjs", "interactive_terminal")
pub fn interactive_terminal() -> Bool

@external(erlang, "kangaroo_terminal_ffi", "dimensions")
@external(javascript, "../../kangaroo_terminal_ffi.mjs", "dimensions")
fn native_dimensions() -> #(Int, Int)

pub fn dimensions() -> #(Int, Int) {
  let #(columns, rows) = native_dimensions()
  normalise_dimensions(columns, rows)
}

/// Enters the alternate screen and raw input mode, and guarantees restoration
/// when the body returns or panics. It is a no-op for redirected terminals.
@external(erlang, "kangaroo_terminal_ffi", "with_ui")
@external(javascript, "../../kangaroo_terminal_ffi.mjs", "with_ui")
pub fn with_ui(body: fn() -> value) -> value

/// Temporarily restores the user's terminal while an interactive child (for
/// example Birdie review) owns stdin, then re-enters the TUI.
@external(erlang, "kangaroo_terminal_ffi", "suspend")
@external(javascript, "../../kangaroo_terminal_ffi.mjs", "suspend")
pub fn suspend(body: fn() -> value) -> value

@external(erlang, "kangaroo_terminal_ffi", "poll_key")
@external(javascript, "../../kangaroo_terminal_ffi.mjs", "poll_key")
pub fn poll_key() -> Option(String)
