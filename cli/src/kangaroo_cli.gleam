import gleam/io
import kangaroo_cli/app
import kangaroo_cli/fs

/// The entry point of the Kangaroo CLI.
///
/// With no arguments it runs the continuous test runner: it watches `src`
/// and `test` for changes and re-runs the tests whenever anything changes.
pub fn main() -> Nil {
  case fs.gleam_executable() {
    Error(message) -> {
      io.println(message)
      fs.sleep(1)
      fs.halt(1)
    }
    Ok(_) -> {
      case fs.current_dir() {
        Error(message) -> {
          io.println("kangaroo: " <> message)
          fs.sleep(1)
          fs.halt(1)
        }
        Ok(project_dir) -> {
          io.println("kangaroo: watching " <> project_dir)
          io.println("kangaroo: press Ctrl+C to stop")
          app.watch(project_dir)
        }
      }
    }
  }
}
