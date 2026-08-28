import gleam/option.{Some, type Option}
import kangaroo_cli/tui.{All, FailuresOnly, type View}

/// What a pressed key should do.
pub type KeyAction {
  Nothing
  /// `r` — force a full re-run of every test module.
  Rerun
  /// `f` — toggle the failures-only view.
  ToggleView
  /// `q` — quit.
  Quit
}

/// Decides what a pressed key should do.
pub fn action(key: Option(String)) -> KeyAction {
  case key {
    Some("r") -> Rerun
    Some("f") -> ToggleView
    Some("q") -> Quit
    // Ctrl+C arrives as the raw byte 0x03 in raw mode.
    Some("\u{3}") -> Quit
    _ -> Nothing
  }
}

/// Toggles between showing every case and only failures.
pub fn toggle_view(view: View) -> View {
  case view {
    All -> FailuresOnly
    FailuresOnly -> All
  }
}
