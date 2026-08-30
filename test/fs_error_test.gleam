import gleam/string
import kangaroo/internal/fs

@external(erlang, "kangaroo_cli_test_ffi", "make_directory_symlink")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "make_directory_symlink")
fn make_directory_symlink(target: String, link: String) -> Bool

pub fn write_parent_errors_are_returned_test() {
  let assert Error(write_error) = fs.write_file("gleam.toml/child", "contents")
  assert write_error != ""
  let assert Error(exclusive_error) =
    fs.write_exclusive("gleam.toml/child", "contents")
  assert exclusive_error != ""
}

pub fn project_output_paths_reject_root_and_traversal_test() {
  let assert Ok(safe) = fs.project_file_path(".", "coverage/lcov.info")
  assert string.ends_with(
    string.replace(safe, each: "\\", with: "/"),
    "/coverage/lcov.info",
  )
  let assert Error(_) = fs.project_file_path(".", "../outside")
  let assert Error(_) = fs.project_file_path(".", "/tmp/outside")
  let assert Error(_) = fs.project_file_path(".", "C:\\outside")
}

pub fn project_output_paths_never_follow_existing_directory_symlinks_test() {
  let assert Ok(workspace) = fs.copy_to_temporary_workspace(".")
  let created =
    make_directory_symlink(workspace <> "/src", workspace <> "/coverage")
  let checked = fs.project_file_path(workspace, "coverage/lcov.info")
  let assert Ok(Nil) = fs.remove_tree(workspace)

  case created {
    True -> {
      let assert Error(message) = checked
      assert string.contains(message, "symbolic link")
    }
    // Some Windows environments do not grant symlink creation privileges;
    // the Linux and macOS matrix still exercises the rejection path.
    False -> Nil
  }
}
