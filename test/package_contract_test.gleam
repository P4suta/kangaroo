import gleam/string
import kangaroo
import kangaroo/internal/fs

pub fn package_interface_configuration_test() {
  let assert Ok(config) = fs.read_file("gleam.toml")

  assert string.contains(config, "\"kangaroo/internal/*\"")
  assert !string.contains(config, "\"kangaroo/coverage_probe\"")
  assert string.contains(config, "gleam = \">= 1.18.0\"")
}

pub fn documented_fixture_labels_compile_and_run_test() {
  let result =
    kangaroo.fixture(
      setup: fn() { 40 },
      teardown: fn(_) { Nil },
      body: fn(value) { value + 2 },
    )
  assert result == 42
}
