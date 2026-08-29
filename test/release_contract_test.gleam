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
    "src/kangaroo_daemon_child.mjs",
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

pub fn protocol_golden_uses_lf_on_every_supported_os_test() {
  let assert Ok(attributes) = fs.read_file(".gitattributes")
  assert string.contains(attributes, "test/golden/*.ndjson text eol=lf")
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
    "Prebuild VS Code fixture daemon",
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
  assert string.contains(workflow, "sha256sum -- ./*")
  assert string.contains(workflow, "CHANGELOG.md")
  assert string.contains(workflow, "npm ci")
  assert string.contains(workflow, "npm run package")
  assert !string.contains(workflow, "npx --yes")
  assert string.contains(
    workflow,
    "RELEASE_TAG: ${{ github.event.release.tag_name }}",
  )
  assert !string.contains(
    workflow,
    "kangaroo-${{ github.event.release.tag_name }}.vsix",
  )
  assert !string.contains(
    workflow,
    "gh release upload \"${{ github.event.release.tag_name }}\"",
  )
}

pub fn runtime_and_ffi_contracts_are_cross_platform_safe_test() {
  let assert Ok(runtime_docs) = fs.read_file("docs/runtimes.md")
  let assert Ok(readme) = fs.read_file("README.md")
  let assert Ok(erlang_fs) = fs.read_file("src/kangaroo_fs_ffi.erl")
  let erlang_fs = string.replace(erlang_fs, each: "\r\n", with: "\n")
  let assert Ok(process_worker) =
    fs.read_file("src/kangaroo_process_worker.mjs")
  let assert Ok(process_ffi) = fs.read_file("src/kangaroo_process_ffi.mjs")
  let assert Ok(erlang_process_ffi) =
    fs.read_file("src/kangaroo_process_ffi.erl")
  let assert Ok(javascript_fs) = fs.read_file("src/kangaroo_fs_ffi.mjs")
  let assert Ok(stdin_worker) = fs.read_file("src/kangaroo_stdin_worker.mjs")
  let assert Ok(test_worker) = fs.read_file("src/kangaroo_test_worker.mjs")
  let assert Ok(terminal_ffi) = fs.read_file("src/kangaroo_terminal_ffi.mjs")
  let assert Ok(erlang_isolate) = fs.read_file("src/kangaroo_isolate_ffi.erl")

  assert string.contains(runtime_docs, "Node.js 22.12+")
  assert string.contains(readme, "Node.js 22.12+")
  assert string.contains(erlang_fs, "file:read_link_info(Path)")
  assert !string.contains(erlang_fs, "case file:read_file_info(Path) of")
  assert string.contains(
    erlang_fs,
    "collect(Directory, Rest, Files);\n        {ok, _Other} ->",
  )
  assert string.contains(process_worker, "child.stdin.on(\"error\"")
  assert string.contains(process_worker, "child.stdin.on(\"close\"")
  assert string.contains(process_worker, "spawnSync(\"taskkill\"")
  assert string.contains(erlang_process_ffi, "taskkill /PID")
  assert string.contains(process_ffi, "activityBuffer")
  assert string.contains(process_worker, "workerData.activityBuffer")
  assert string.contains(javascript_fs, "observedActivity")
  assert string.contains(stdin_worker, "workerData.activityBuffer")
  assert string.contains(test_worker, "Atomics.compareExchange(childPids")
  assert !string.contains(terminal_ffi, "readSync")
  assert string.contains(terminal_ffi, "receiveMessageOnPort")
  assert fs.exists("src/kangaroo_key_worker.mjs")
  assert string.contains(erlang_isolate, "kangaroo_stderr_table_timeout")
}

pub fn coverage_probe_is_a_downstream_importable_tooling_module_test() {
  let assert Ok(config) = fs.read_file("gleam.toml")
  let assert Ok(workflow) = fs.read_file(".github/workflows/test.yml")
  let assert Ok(architecture) = fs.read_file("ARCHITECTURE.md")

  assert fs.exists("src/kangaroo/coverage_probe.gleam")
  assert !string.contains(config, "internal_modules = [\"kangaroo/*\"]")
  assert string.contains(workflow, "\"kangaroo/coverage_probe\"")
  assert string.contains(architecture, "kangaroo/coverage_probe")
  assert string.contains(architecture, "tooling ABI")
}

pub fn neovim_installation_uses_a_supported_lazy_nvim_spec_test() {
  let assert Ok(readme) = fs.read_file("editors/neovim/README.md")

  assert !string.contains(readme, "subdir =")
  assert string.contains(readme, "vim.opt.rtp:append")
  assert string.contains(readme, "require(\"kangaroo\").setup()")
}
