import gleam/dict.{type Dict}
import gleam/list

/// A file that changed between two snapshots.
pub type FileChange {
  Added(path: String)
  Modified(path: String)
  Removed(path: String)
}

/// Metadata about a watched file, captured from the filesystem. `mtime` is
/// in milliseconds and may be second-granular on some platforms; `size` is
/// used to catch writes that do not advance the clock.
pub type FileMeta {
  FileMeta(mtime: Int, size: Int)
}

/// A snapshot of the watched files' metadata.
pub type Snapshot {
  Snapshot(files: Dict(String, FileMeta))
}

/// An empty snapshot.
pub fn snapshot() -> Snapshot {
  Snapshot(dict.new())
}

/// Adds a file to a snapshot.
pub fn insert(snapshot: Snapshot, path: String, meta: FileMeta) -> Snapshot {
  Snapshot(dict.insert(snapshot.files, path, meta))
}

/// Compares two snapshots of file metadata and reports what changed between
/// them. A file is modified when its modification time or its size changed.
pub fn diff(previous: Snapshot, current: Snapshot) -> List(FileChange) {
  let keys =
    dict.keys(previous.files)
    |> list.append(dict.keys(current.files))
    |> list.unique

  list.filter_map(keys, fn(path) {
    case dict.get(previous.files, path), dict.get(current.files, path) {
      Error(_), Ok(_) -> Ok(Added(path))
      Ok(old), Ok(new) if old != new -> Ok(Modified(path))
      Ok(_), Error(_) -> Ok(Removed(path))
      _, _ -> Error(Nil)
    }
  })
}

/// Compares two snapshots of file contents. This catches edits that
/// metadata cannot distinguish, such as two writes within the same second
/// that keep the file size unchanged.
pub fn diff_contents(
  previous: Dict(String, String),
  current: Dict(String, String),
) -> List(FileChange) {
  let keys =
    dict.keys(previous)
    |> list.append(dict.keys(current))
    |> list.unique

  list.filter_map(keys, fn(path) {
    case dict.get(previous, path), dict.get(current, path) {
      Error(_), Ok(_) -> Ok(Added(path))
      Ok(old), Ok(new) if old != new -> Ok(Modified(path))
      Ok(_), Error(_) -> Ok(Removed(path))
      _, _ -> Error(Nil)
    }
  })
}
