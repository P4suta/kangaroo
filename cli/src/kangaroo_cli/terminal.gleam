import gleam/option.{type Option}

/// Terminal access for the TUI: raw-mode input and TTY detection.
///
/// Keyboard input is fully supported on Erlang (a background reader
/// process plus a signal handler that restores the terminal); on
/// JavaScript `poll_key` always returns `None` for now.
/// Whether stdout is a terminal.
@external(erlang, "kangaroo_cli_ffi", "is_tty")
@external(javascript, "../kangaroo_cli_ffi.mjs", "is_tty")
pub fn is_tty() -> Bool

/// Puts the terminal into raw mode (single-key input, no echo) or restores
/// it. No-op when stdout is not a terminal.
@external(erlang, "kangaroo_cli_ffi", "raw_mode")
@external(javascript, "../kangaroo_cli_ffi.mjs", "raw_mode")
pub fn raw_mode(on: Bool) -> Nil

/// Starts the background keyboard reader and installs a SIGINT handler
/// that restores the terminal before exiting. Erlang only.
@external(erlang, "kangaroo_cli_ffi", "init_keyboard")
@external(javascript, "../kangaroo_cli_ffi.mjs", "init_keyboard")
pub fn init_keyboard() -> Nil

/// Returns the next pressed key, if one is waiting. Erlang only; always
/// `None` on JavaScript.
@external(erlang, "kangaroo_cli_ffi", "poll_key")
@external(javascript, "../kangaroo_cli_ffi.mjs", "poll_key")
pub fn poll_key() -> Option(String)
