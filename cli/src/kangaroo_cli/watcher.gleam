import gleam/dict.{type Dict}
import gleam/list

/// A file that changed between two snapshots.
pub type FileChange {
  Added(path: String)
  Modified(path: String)
  Removed(path: String)
}

/// Compares two snapshots of file modification times and reports what
/// changed between them.
pub fn diff(
  previous: Dict(String, Int),
  current: Dict(String, Int),
) -> List(FileChange) {
  let keys = dict.keys(previous) |> list.append(dict.keys(current)) |> list.unique

  list.filter_map(keys, fn(path) {
    case dict.get(previous, path), dict.get(current, path) {
      Error(_), Ok(_) -> Ok(Added(path))
      Ok(old), Ok(new) if old != new -> Ok(Modified(path))
      Ok(_), Error(_) -> Ok(Removed(path))
      _, _ -> Error(Nil)
    }
  })
}
