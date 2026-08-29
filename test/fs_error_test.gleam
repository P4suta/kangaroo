import kangaroo/internal/fs

pub fn write_parent_errors_are_returned_test() {
  let assert Error(write_error) = fs.write_file("gleam.toml/child", "contents")
  assert write_error != ""
  let assert Error(exclusive_error) =
    fs.write_exclusive("gleam.toml/child", "contents")
  assert exclusive_error != ""
}
