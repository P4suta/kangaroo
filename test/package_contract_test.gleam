import gleam/string
import kangaroo/internal/fs

pub fn package_interface_configuration_test() {
  let assert Ok(config) = fs.read_file("gleam.toml")

  assert string.contains(config, "internal_modules = [\"kangaroo/*\"]")
  assert string.contains(config, "gleam = \">= 1.18.0\"")
}
