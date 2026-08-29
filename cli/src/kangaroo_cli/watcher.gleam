import gleam/dict.{type Dict}
import gleam/list
import gleam/string

/// A file that changed between two snapshots.
pub type FileChange {
  Added(path: String)
  Modified(path: String)
  Removed(path: String)
}

/// An entry in a directory listing: the entry name and whether it is a
/// directory.
pub type DirEntry {
  DirEntry(name: String, is_dir: Bool)
}

/// An incremental directory walk over the watched trees. The walk holds
/// the roots that must always be re-checked, every directory known to
/// exist (with its modification time), and every file path discovered so
/// far. Each step re-stats the directories and re-lists only the ones
/// whose modification time advanced, so unchanged trees cost a few stats
/// instead of a full rescan.
pub type Walk {
  Walk(
    roots: List(String),
    directories: Dict(String, Int),
    files: Dict(String, Nil),
  )
}

/// Seeds a walk with the given root directories. Every root is recorded
/// with a zero timestamp, so the first step lists it; roots that do not
/// exist are kept and re-checked until they appear.
pub fn walk(roots: List(String)) -> Walk {
  Walk(
    roots,
    dict.from_list(list.map(roots, fn(dir) { #(dir, 0) })),
    dict.new(),
  )
}

/// The files currently known to the walk, sorted for determinism.
pub fn walk_files(walk: Walk) -> List(String) {
  list.sort(dict.keys(walk.files), string.compare)
}

/// Advances the walk one step: every root and known directory is
/// re-statted, and directories whose modification time advanced are
/// re-listed. New files and directories are discovered, vanished files
/// and directories are reported as removed. Returns the next walk and the
/// structural changes observed.
pub fn walk_advance(
  walk: Walk,
  directory_mtime: fn(String) -> Result(Int, Nil),
  list_directory: fn(String) -> Result(List(DirEntry), Nil),
) -> #(Walk, List(FileChange)) {
  let known = list.sort(dict.keys(walk.directories), string.compare)
  let directories = list.unique(list.append(walk.roots, known))
  list.fold(directories, #(walk, []), fn(state, dir) {
    let #(walk, changes) = state
    case directory_mtime(dir) {
      Error(_) ->
        case list.contains(walk.roots, dir) {
          // A root that does not exist (yet): keep waiting for it.
          True -> state
          // A directory that disappeared: drop it and its files.
          False -> drop_directory(walk, changes, dir)
        }
      Ok(mtime) ->
        case dict.get(walk.directories, dir) {
          Ok(cached) if cached == mtime -> state
          _ ->
            case list_directory(dir) {
              Error(_) -> state
              Ok(entries) ->
                re_list(walk, changes, dir, mtime, entries, directory_mtime)
            }
        }
    }
  })
}

fn re_list(
  walk: Walk,
  changes: List(FileChange),
  dir: String,
  mtime: Int,
  entries: List(DirEntry),
  directory_mtime: fn(String) -> Result(Int, Nil),
) -> #(Walk, List(FileChange)) {
  let prefix = dir <> "/"
  let names = list.map(entries, fn(entry) { prefix <> entry.name })

  let new_files =
    list.filter(entries, fn(entry) {
      entry.is_dir == False && !dict.has_key(walk.files, prefix <> entry.name)
    })
  let new_dirs =
    list.filter(entries, fn(entry) {
      entry.is_dir == True
      && !dict.has_key(walk.directories, prefix <> entry.name)
    })
  let removed =
    list.filter(direct_files_under(walk, dir), fn(path) {
      !list.contains(names, path)
    })
  let removed_dirs =
    list.filter(direct_dirs_under(walk, dir), fn(path) {
      !list.contains(names, path)
    })

  let walk = put_directory(walk, dir, mtime)
  let walk =
    list.fold(new_files, walk, fn(walk, entry) {
      put_file(walk, prefix <> entry.name)
    })
  let walk =
    list.fold(new_dirs, walk, fn(walk, entry) {
      let mtime = case directory_mtime(prefix <> entry.name) {
        Ok(mtime) -> mtime
        Error(_) -> 0
      }
      put_directory(walk, prefix <> entry.name, mtime)
    })
  let walk = list.fold(removed, walk, remove_file)
  let #(walk, changes) =
    list.fold(removed_dirs, #(walk, changes), fn(state, dir) {
      let #(walk, changes) = state
      let walk = remove_directory(walk, dir)
      let removed_files = files_under(walk, dir)
      let walk = list.fold(removed_files, walk, remove_file)
      #(walk, list.append(changes, list.map(removed_files, Removed)))
    })

  let added = list.map(new_files, fn(entry) { Added(prefix <> entry.name) })
  let removed_changes = list.map(removed, Removed)
  #(walk, list.append(changes, list.append(added, removed_changes)))
}

/// Drops a directory that disappeared, together with every file known
/// under it, and reports the files as removed.
fn drop_directory(
  walk: Walk,
  changes: List(FileChange),
  dir: String,
) -> #(Walk, List(FileChange)) {
  let removed = files_under(walk, dir)
  let walk = remove_directory(walk, dir)
  let walk = list.fold(removed, walk, remove_file)
  #(walk, list.append(changes, list.map(removed, Removed)))
}

/// The files whose path is a direct child of the given directory. A
/// directory's listing only contains its own entries, so a re-listed
/// directory must only compare against these.
fn direct_files_under(walk: Walk, dir: String) -> List(String) {
  let prefix = dir <> "/"
  dict.keys(walk.files)
  |> list.filter(fn(path) {
    string.starts_with(path, prefix)
    && !string.contains(string.drop_start(path, string.length(prefix)), "/")
  })
}

/// The directories known under the given directory as direct children. A
/// directory that vanishes from its parent's listing is removed together
/// with everything known under it.
fn direct_dirs_under(walk: Walk, dir: String) -> List(String) {
  let prefix = dir <> "/"
  dict.keys(walk.directories)
  |> list.filter(fn(path) {
    string.starts_with(path, prefix)
    && !string.contains(string.drop_start(path, string.length(prefix)), "/")
  })
}

/// Every file known under the directory, at any depth. Used when the
/// directory itself disappears.
fn files_under(walk: Walk, dir: String) -> List(String) {
  let prefix = dir <> "/"
  dict.keys(walk.files)
  |> list.filter(fn(path) { string.starts_with(path, prefix) })
}

fn put_file(walk: Walk, path: String) -> Walk {
  Walk(walk.roots, walk.directories, dict.insert(walk.files, path, Nil))
}

fn remove_file(walk: Walk, path: String) -> Walk {
  Walk(walk.roots, walk.directories, dict.delete(walk.files, path))
}

fn put_directory(walk: Walk, dir: String, mtime: Int) -> Walk {
  Walk(walk.roots, dict.insert(walk.directories, dir, mtime), walk.files)
}

fn remove_directory(walk: Walk, dir: String) -> Walk {
  Walk(walk.roots, dict.delete(walk.directories, dir), walk.files)
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
