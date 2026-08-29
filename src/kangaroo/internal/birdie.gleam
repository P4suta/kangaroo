import gleam/list
import gleam/result
import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/watcher

pub fn arguments() -> List(String) {
  ["run", "-m", "birdie"]
}

pub fn rerun_after_review(exit_code: Int) -> Bool {
  exit_code == 0
}

pub fn select_pending(paths: List(String)) -> List(String) {
  paths
  |> list.map(watcher.normalise_path)
  |> list.filter(fn(path) {
    let snapshot_directory =
      string.starts_with(path, "test/birdie_snapshots/")
      || string.starts_with(path, "birdie_snapshots/")
    snapshot_directory && string.ends_with(path, ".new")
  })
  |> list.unique
  |> list.sort(string.compare)
}

pub fn relative_path(project_dir: String, path: String) -> String {
  let project_dir =
    project_dir |> watcher.normalise_path |> trim_trailing_separators
  let path = watcher.normalise_path(path)
  let prefix = project_dir <> "/"
  case string.starts_with(path, prefix) {
    True -> string.drop_start(path, string.length(prefix))
    False -> path
  }
}

fn trim_trailing_separators(path: String) -> String {
  case path {
    "" | "/" -> path
    _ ->
      case string.ends_with(path, "/") {
        True -> trim_trailing_separators(string.remove_suffix(path, "/"))
        False -> path
      }
  }
}

pub fn pending(project_dir: String) -> Result(List(String), String) {
  let directories = [
    project_dir <> "/test/birdie_snapshots",
    project_dir <> "/birdie_snapshots",
  ]
  use files <- result.try(
    list.try_fold(directories, [], fn(files, directory) {
      case fs.is_directory(directory) {
        False -> Ok(files)
        True ->
          fs.list_files_recursive(directory)
          |> result.map(fn(found) { list.append(files, found) })
      }
    }),
  )
  files
  |> list.map(fn(path) { relative_path(project_dir, path) })
  |> select_pending
  |> Ok
}
