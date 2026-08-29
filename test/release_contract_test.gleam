import gleam/list
import gleam/string
import kangaroo/internal/fs

pub fn required_release_files_test() {
  [
    "LICENSE",
    "SECURITY.md",
    "CONTRIBUTING.md",
    "CODE_OF_CONDUCT.md",
    "docs/migration-from-gleeunit.md",
    "docs/runtimes.md",
    "docs/integrations.md",
    "docs/troubleshooting.md",
    "docs/protocol-v1.schema.json",
    "benchmarks/v1-baseline.json",
    "editors/vscode/package-lock.json",
    "scripts/hex_clean_install_test.py",
    "scripts/test_hex_clean_install.py",
  ]
  |> list.each(fn(path) {
    assert fs.exists(path)
  })
}

pub fn readme_describes_the_v1_contract_test() {
  let assert Ok(readme) = fs.read_file("README.md")

  [
    "import kangaroo",
    "kangaroo.main()",
    "pub fn addition_test()",
    "gleam test",
    "gleam run -m kangaroo -- watch",
    "[tools.kangaroo]",
    "Erlang",
    "Node.js",
    "Bun",
    "Deno",
  ]
  |> list.each(fn(fragment) {
    assert string.contains(readme, fragment)
  })

  assert !string.contains(readme, "kangaroo_cli")
  assert !string.contains(readme, "suite(")
  assert !string.contains(readme, "expect(")
}

pub fn documentation_has_no_removed_package_or_dsl_test() {
  ["ARCHITECTURE.md", "CHANGELOG.md", "docs/protocol.md"]
  |> list.each(fn(path) {
    let assert Ok(contents) = fs.read_file(path)
    assert !string.contains(contents, "kangaroo_cli")
    assert !string.contains(contents, "suite / it / expect")
  })
}

pub fn generated_validation_artifacts_are_ignored_test() {
  let assert Ok(ignore) = fs.read_file(".gitignore")
  [
    "benchmark-result.json",
    "nvim.log",
    "**/__pycache__/",
    "**/.kangaroo-benchmark-*/",
  ]
  |> list.each(fn(pattern) {
    assert string.contains(ignore, pattern)
  })
}

pub fn ci_covers_the_supported_platforms_and_runtimes_test() {
  let assert Ok(workflow) = fs.read_file(".github/workflows/test.yml")

  [
    "ubuntu-latest",
    "macos-latest",
    "windows-latest",
    "erlang",
    "node",
    "bun",
    "deno",
    "gleam format --check",
    "warnings-as-errors",
    "python3 -W error::ResourceWarning -m unittest scripts/test_benchmark.py",
    "python3 scripts/benchmark.py",
    "benchmark-result.json",
    "npm run test:integration",
    "nvim-linux-x86_64.tar.gz",
    "npm ci",
    "python3 -W error::ResourceWarning -m unittest scripts/test_hex_clean_install.py",
    "python3 scripts/hex_clean_install_test.py",
    "working-directory: fixtures/watch_project",
  ]
  |> list.each(fn(fragment) {
    assert string.contains(workflow, fragment)
  })
}

pub fn release_is_one_versioned_package_test() {
  let assert Ok(config) = fs.read_file("release-please-config.json")
  let assert Ok(manifest) = fs.read_file(".release-please-manifest.json")
  let assert Ok(workflow) = fs.read_file(".github/workflows/release-please.yml")

  assert !string.contains(config, "cli")
  assert !string.contains(workflow, "cli")
  assert string.contains(manifest, "1.0.0")
  assert string.contains(workflow, "gleam publish")
  assert string.contains(workflow, "vsce publish")
  assert string.contains(workflow, "ovsx publish")
  assert string.contains(workflow, "checksums")
  assert string.contains(workflow, "CHANGELOG.md")
  assert string.contains(workflow, "npm ci")
  assert string.contains(workflow, "npm run package")
  assert !string.contains(workflow, "npx --yes")
}
