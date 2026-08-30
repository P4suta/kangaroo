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
    "docs/release-checklist.md",
    "benchmarks/v1-baseline.json",
    "editors/vscode/package-lock.json",
    "editors/vscode/download-test-host.js",
    "scripts/hex_clean_install_test.py",
    "scripts/test_hex_clean_install.py",
    "scripts/publish_hex_tarball.py",
    "scripts/test_publish_hex_tarball.py",
    "priv/kangaroo_windows_job.ps1",
    "src/kangaroo_daemon_child.mjs",
    "src/kangaroo_batch_worker.mjs",
    "src/kangaroo_windows_job.mjs",
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
  ["ARCHITECTURE.md", "docs/protocol.md"]
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
  let assert Ok(vscode_manifest) = fs.read_file("editors/vscode/package.json")

  [
    "ubuntu-latest",
    "macos-latest",
    "windows-latest",
    "erlang",
    "node",
    "bun",
    "deno",
    "gleam format --check",
    "gleam format --check src dev test fixtures",
    "warnings-as-errors",
    "python3 -W error::ResourceWarning -m unittest scripts/test_benchmark.py",
    "python3 scripts/benchmark.py",
    "benchmark-result.json",
    "npm run test:integration",
    "npm run download:test-host",
    "Cache pinned VS Code test host",
    "Prebuild VS Code fixture daemon",
    "Cache pinned Neovim archive",
    "releases/download/v0.12.5/nvim-linux-x86_64.tar.gz",
    "bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875",
    "--retry-all-errors",
    "nvim-linux-x86_64.tar.gz",
    "npm ci",
    "python3 -W error::ResourceWarning -m unittest scripts/test_hex_clean_install.py",
    "python3 scripts/hex_clean_install_test.py",
    "working-directory: fixtures/watch_project",
    "22.12.0",
    "Repeat process and daemon lifecycle 20 times",
    "Repeat Erlang process and daemon lifecycle 20 times",
  ]
  |> list.each(fn(fragment) {
    assert string.contains(workflow, fragment)
  })

  assert string.contains(vscode_manifest, "--code-version 1.95.3")
}

pub fn release_is_one_versioned_package_test() {
  let assert Ok(config) = fs.read_file("release-please-config.json")
  let assert Ok(manifest) = fs.read_file(".release-please-manifest.json")
  let assert Ok(workflow) = fs.read_file(".github/workflows/release-please.yml")
  let assert Ok(hex_publisher) = fs.read_file("scripts/publish_hex_tarball.py")
  let assert Ok(command_source) =
    fs.read_file("src/kangaroo/internal/command.gleam")

  assert !string.contains(config, "cli")
  assert !string.contains(workflow, "cli")
  assert string.contains(config, "src/kangaroo/internal/command.gleam")
  assert string.contains(config, "editors/vscode/package-lock.json")
  assert string.contains(config, "$.packages[''].version")
  assert string.contains(command_source, "x-release-please-start-version")
  assert string.contains(command_source, "x-release-please-end")
  assert string.contains(manifest, "1.0.0")
  assert string.contains(workflow, "scripts/publish_hex_tarball.py")
  assert string.contains(workflow, "vsce publish")
  assert string.contains(workflow, "ovsx publish")
  assert string.contains(workflow, "checksums")
  assert string.contains(workflow, "build-release-artifacts:")
  assert string.contains(workflow, "publish-github-assets:")
  assert string.contains(workflow, "publish-hex:")
  assert string.contains(workflow, "publish-vscode-marketplace:")
  assert string.contains(workflow, "publish-open-vsx:")
  assert string.contains(workflow, "actions/upload-artifact@v4")
  assert string.contains(workflow, "actions/download-artifact@v4")
  assert string.contains(workflow, "id: release")
  assert string.contains(workflow, "id: release-bootstrap")
  assert string.contains(
    workflow,
    "if: steps.release-bootstrap.outputs.ready == 'true'",
  )
  assert string.contains(workflow, "refs/tags/v${current_version}")
  assert string.contains(
    workflow,
    "needs.release-please.outputs.release_created == 'true'",
  )
  assert string.contains(
    workflow,
    "needs.build-release-artifacts.outputs.tag_name",
  )
  assert string.contains(workflow, "github.event_name == 'push'")
  assert string.contains(
    workflow,
    "test \"${RELEASE_TAG}\" = \"v${release_version}\"",
  )
  assert string.contains(workflow, "overwrite: false")
  assert !string.contains(workflow, "overwrite: true")
  assert string.contains(workflow, "Restore the immutable release artifact")
  assert string.contains(
    workflow,
    "Protect the canonical artifact from rebuilds",
  )
  assert string.contains(workflow, "gh release download")
  assert string.contains(workflow, "actions/artifacts")
  assert string.contains(workflow, "if length == 1")
  assert string.contains(workflow, "Refusing to regenerate publication bytes")
  assert string.contains(workflow, "GITHUB_RUN_ATTEMPT")
  assert string.contains(workflow, "sha256sum --check checksums.txt")
  assert !string.contains(workflow, "sha256sum -- ./*")
  assert !string.contains(workflow, "--clobber")
  assert string.contains(workflow, "cmp --silent")
  assert string.contains(workflow, "Refusing to overwrite it")
  assert string.contains(workflow, "CHANGELOG.md")
  assert string.contains(workflow, "npm ci")
  assert string.contains(workflow, "npm run package")
  assert string.contains(
    workflow,
    "python3 scripts/hex_clean_install_test.py \"build/kangaroo-${RELEASE_VERSION}.tar\"",
  )
  assert string.contains(
    workflow,
    "require(\"./editors/vscode/package-lock.json\").version",
  )
  assert string.contains(
    workflow,
    "require(\"./editors/vscode/package-lock.json\").packages[\"\"]?.version",
  )
  assert string.contains(workflow, "--repo \"${GITHUB_REPOSITORY}\"")
  assert string.contains(hex_publisher, "https://repo.hex.pm")
  assert string.contains(hex_publisher, "application/octet-stream")
  assert string.contains(hex_publisher, "already-published")
  assert !string.contains(workflow, "gleam publish")
  assert string.contains(workflow, "Publish the exact Hex package artifact")
  assert string.contains(workflow, "repo.hex.pm/docs/kangaroo-")
  assert string.contains(workflow, "gleam docs publish")
  assert string.contains(
    workflow,
    "vsce publish --skip-duplicate --packagePath",
  )
  assert string.contains(workflow, "ovsx publish --skip-duplicate")
  assert !string.contains(workflow, "--pat \"$OVSX_PAT\"")
  assert !string.contains(workflow, "npx --yes")
  assert string.contains(
    workflow,
    "RELEASE_TAG: ${{ needs.build-release-artifacts.outputs.tag_name }}",
  )
  assert string.contains(workflow, "workflow_dispatch:")
  assert !string.contains(
    workflow,
    "kangaroo-${{ github.event.release.tag_name }}.vsix",
  )
  assert !string.contains(
    workflow,
    "gh release upload \"${{ github.event.release.tag_name }}\"",
  )
}

pub fn first_release_runbook_is_fail_closed_and_rerunnable_test() {
  let assert Ok(checklist) = fs.read_file("docs/release-checklist.md")
  let assert Ok(contributing) = fs.read_file("CONTRIBUTING.md")

  [
    "PR #12",
    "PR #11",
    "v1.0.0",
    "exact merge commit",
    "HEXPM_API_KEY",
    "VSCE_PAT",
    "OVSX_PAT",
    "workflow_dispatch",
    "target",
    "Do not regenerate",
    "byte-for-byte",
  ]
  |> list.each(fn(fragment) {
    assert string.contains(checklist, fragment)
  })

  assert string.contains(contributing, "docs/release-checklist.md")
}

pub fn runtime_and_ffi_contracts_are_cross_platform_safe_test() {
  let assert Ok(runtime_docs) = fs.read_file("docs/runtimes.md")
  let assert Ok(readme) = fs.read_file("README.md")
  let assert Ok(workflow) = fs.read_file(".github/workflows/test.yml")
  let assert Ok(erlang_fs) = fs.read_file("src/kangaroo_fs_ffi.erl")
  let erlang_fs = string.replace(erlang_fs, each: "\r\n", with: "\n")
  let assert Ok(process_worker) =
    fs.read_file("src/kangaroo_process_worker.mjs")
  let assert Ok(batch_worker) = fs.read_file("src/kangaroo_batch_worker.mjs")
  let assert Ok(javascript_vm) = fs.read_file("src/kangaroo_vm_ffi.mjs")
  let assert Ok(daemon_source) =
    fs.read_file("src/kangaroo/internal/daemon.gleam")
  let assert Ok(process_tree) = fs.read_file("src/kangaroo_process_tree.mjs")
  let assert Ok(process_ffi) = fs.read_file("src/kangaroo_process_ffi.mjs")
  let assert Ok(erlang_process_ffi) =
    fs.read_file("src/kangaroo_process_ffi.erl")
  let assert Ok(javascript_fs) = fs.read_file("src/kangaroo_fs_ffi.mjs")
  let assert Ok(stdin_worker) = fs.read_file("src/kangaroo_stdin_worker.mjs")
  let assert Ok(test_worker) = fs.read_file("src/kangaroo_test_worker.mjs")
  let assert Ok(terminal_ffi) = fs.read_file("src/kangaroo_terminal_ffi.mjs")
  let assert Ok(erlang_isolate) = fs.read_file("src/kangaroo_isolate_ffi.erl")
  let assert Ok(windows_job) = fs.read_file("priv/kangaroo_windows_job.ps1")
  let assert Ok(windows_job_bridge) =
    fs.read_file("src/kangaroo_windows_job.mjs")
  let assert Ok(windows_open_port_smoke) =
    fs.read_file("scripts/windows_open_port_smoke.escript")

  assert string.contains(runtime_docs, "Node.js 22.12+")
  assert string.contains(readme, "Node.js 22.12+")
  assert string.contains(erlang_fs, "file:read_link_info(Path)")
  assert string.contains(
    erlang_fs,
    "copy_cleanup_error(\n                      Reason, remove_tree(Destination))",
  )
  assert !string.contains(
    erlang_fs,
    "{error, Reason} ->\n                    _ = remove_directory(Destination)",
  )
  assert !string.contains(erlang_fs, "case file:read_file_info(Path) of")
  assert string.contains(
    erlang_fs,
    "collect(Directory, Rest, Files);\n        {ok, _Other} ->",
  )
  assert string.contains(process_worker, "child.stdin.on(\"error\"")
  assert string.contains(batch_worker, "run_batch_wire")
  assert string.contains(batch_worker, "KANGAROO_COVERAGE_FILE")
  assert string.contains(javascript_vm, "export function run_batches")
  assert string.contains(javascript_vm, "appendFileSync")
  assert string.contains(process_worker, "child.stdin.on(\"close\"")
  assert string.contains(process_worker, "globalThis.Bun.spawn")
  assert string.contains(process_worker, "new TextDecoder()")
  assert string.contains(process_worker, "from \"./kangaroo_process_tree.mjs\"")
  assert string.contains(process_worker, "pendingTermination")
  assert string.contains(process_worker, "finishTermination")
  assert string.contains(process_worker, "message.type === \"consumed\"")
  assert string.contains(daemon_source, "process.start_streaming(")
  assert string.contains(daemon_source, "operations.append_output_checked(")
  assert string.contains(daemon_source, "entry.terminal_error")
  let assert [_, termination_body] =
    string.split(process_worker, "function terminateTree(message)")
  let assert [termination_body, ..] =
    string.split(termination_body, "let child")
  assert !string.contains(termination_body, "finish(message)")
  assert string.contains(
    process_ffi,
    "process cancellation did not settle within",
  )
  assert string.contains(process_tree, "processTreeExecFileSync(\"taskkill\"")
  let assert [taskkill_prefix, ..] =
    string.split(process_tree, "globalThis.process.kill(pid")
  assert string.contains(
    taskkill_prefix,
    "processTreeExecFileSync(\"taskkill\"",
  )
  assert string.contains(erlang_process_ffi, "taskkill /PID")
  assert string.contains(erlang_process_ffi, "windows_job_launch")
  assert string.contains(erlang_process_ffi, "windows_job_executable")
  assert string.contains(erlang_process_ffi, "windows_command_processor")
  assert string.contains(erlang_process_ffi, "os:find_executable(\"cmd.exe\")")
  assert string.contains(erlang_process_ffi, "filename:dirname(Helper)")
  assert string.contains(erlang_process_ffi, "filename:basename(Helper)")
  assert string.contains(erlang_process_ffi, "\"--kangaroo-job-helper\"")
  assert string.contains(erlang_process_ffi, "ENVIRONMENT_NAME_")
  assert string.contains(erlang_process_ffi, "ENVIRONMENT_VALUE_")
  let assert [_, preparation_body] =
    string.split(erlang_process_ffi, "\nprepare_windows_job_helper_worker() ->")
  let assert [preparation_body, ..] =
    string.split(preparation_body, "collect_windows_job_preparation(")
  assert string.contains(preparation_body, "\"-Prepare\"")
  assert !string.contains(preparation_body, "\"-OutputPath\"")
  assert string.contains(preparation_body, "filelib:ensure_dir(Helper)")
  assert string.contains(
    preparation_body,
    "stage_windows_job_preparation(Helper)",
  )
  assert string.contains(preparation_body, "{ok, CommandProcessor}")
  assert string.contains(
    preparation_body,
    "{spawn_executable, CommandProcessor}",
  )
  assert string.contains(preparation_body, "filename:basename(PowerShell)")
  assert !string.contains(preparation_body, "{spawn_executable, PowerShell}")
  assert string.contains(preparation_body, "{cd, filename:dirname(Helper)}")
  assert !string.contains(
    preparation_body,
    "windows_job_output_path_environment",
  )
  assert !string.contains(
    erlang_process_ffi,
    "windows_job_output_path_environment(Helper)",
  )
  assert string.contains(preparation_body, "default_windows_job_executable()")
  assert string.contains(erlang_process_ffi, "filename:absname(")
  assert !string.contains(preparation_body, "\"-PrintHelperPath\"")
  assert !string.contains(erlang_process_ffi, "windows_helper_path(Output)")
  assert !string.contains(erlang_process_ffi, "KANGAROO_HELPER_PATH_BASE64=")
  assert string.contains(erlang_process_ffi, "find_windows_powershell")
  assert string.contains(
    erlang_process_ffi,
    "os:find_executable(\"powershell.exe\")",
  )
  assert string.contains(process_worker, "windowsJobLaunch")
  assert string.contains(test_worker, "windowsJobSpawnOptions")
  assert string.contains(test_worker, "windowsJobLaunch")
  assert string.contains(windows_job_bridge, "kangaroo_windows_job.ps1")
  assert string.contains(windows_job_bridge, "windowsJobSpawnOptions")
  assert string.contains(windows_job_bridge, "ensureWindowsJobHelper")
  assert string.contains(windows_job_bridge, "globalThis.process.env.TEMP")
  assert string.contains(windows_job_bridge, "globalThis.process.env.TMP")
  assert string.contains(windows_job_bridge, "globalThis.process.env.TMPDIR")
  assert string.contains(windows_job_bridge, "String(value).trim() !== \"\"")
  assert !string.contains(windows_job_bridge, "tmpdir()")
  assert string.contains(windows_job_bridge, "mkdirSync")
  assert string.contains(windows_job_bridge, "dirname(cachedExecutable)")
  assert string.contains(windows_job_bridge, "cwd: dirname(cachedExecutable)")
  assert string.contains(windows_job, "RemoveInternalVariables")
  assert string.contains(windows_job, "OrdinalIgnoreCase")
  assert string.contains(windows_job, "EnvironmentVariableTarget.Process")
  assert string.contains(windows_job, "CREATE_SUSPENDED")
  assert string.contains(windows_job, "AssignProcessToJobObject")
  assert string.contains(windows_job, "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE")
  assert string.contains(windows_job, "TerminateRemainingProcesses(job)")
  assert !string.contains(windows_job, "DateTime.UtcNow.AddSeconds")
  assert string.contains(windows_job, "-OutputAssembly")
  assert string.contains(windows_job, "windows-job-v6-20260831.exe")
  assert !string.contains(windows_job, "windows-job-v6-20260831.cmd")
  assert string.contains(windows_job_bridge, "windows-job-v6-20260831.exe")
  assert string.contains(erlang_process_ffi, "windows-job-v6-20260831.exe")
  assert string.contains(windows_job_bridge, "findPowerShell")
  assert string.contains(windows_job_bridge, "pwsh.exe")
  assert !string.contains(windows_job_bridge, "HelperPath")
  assert string.contains(windows_job, "[string] $OutputPath")
  assert !string.contains(windows_job, "$prefix + \"OUTPUT_PATH\"")
  assert string.contains(
    windows_job,
    "[Environment]::GetEnvironmentVariable(\n        \"TEMP\"",
  )
  assert string.contains(
    windows_job,
    "[Environment]::GetEnvironmentVariable(\n            \"TMP\"",
  )
  assert string.contains(
    windows_job,
    "[Environment]::GetEnvironmentVariable(\n            \"TMPDIR\"",
  )
  assert !string.contains(windows_job, "[switch] $PrintHelperPath")
  assert !string.contains(windows_job, "function Write-Ascii-Line")
  assert string.contains(windows_job, "ConsoleApplication")
  assert string.contains(workflow, "kangaroo_windows_job.ps1 -SmokeTest")
  assert string.contains(workflow, "windows_open_port_smoke.escript")
  assert string.contains(erlang_process_ffi, "windows-job-prepare-v6-20260831-")
  assert string.contains(
    windows_open_port_smoke,
    "require_executable(\"cmd.exe\")",
  )
  assert string.contains(
    windows_open_port_smoke,
    "{spawn_executable, CommandProcessor}",
  )
  assert !string.contains(
    windows_open_port_smoke,
    "{spawn_executable, PowerShell}",
  )
  assert !string.contains(
    windows_open_port_smoke,
    "windows_job_output_path_environment(Helper)",
  )
  assert string.contains(
    windows_open_port_smoke,
    "{cd, filename:dirname(Helper)}",
  )
  let assert [_, helper_path_body] =
    string.split(windows_job, "function Get-Helper-Path {")
  let assert [helper_path_body, ..] =
    string.split(helper_path_body, "function Ensure-Job-Executable")
  assert !string.contains(windows_job, "GetTempPath")
  assert string.contains(helper_path_body, "if ($Prepare)")
  assert string.contains(helper_path_body, "[Environment]::CurrentDirectory")
  assert !string.contains(helper_path_body, "(Get-Location).ProviderPath")
  assert string.contains(windows_job, "DuplicateHandle")
  assert string.contains(process_ffi, "activityBuffer")
  assert string.contains(process_worker, "workerData.activityBuffer")
  assert string.contains(javascript_fs, "observedActivity")
  assert string.contains(
    javascript_fs,
    "if (ownerWritten) removeOwnedCoverageWorkspace(destination)",
  )
  assert !string.contains(
    javascript_fs,
    "if (destination) rmSync(destination, { recursive: true",
  )
  assert string.contains(stdin_worker, "workerData.activityBuffer")
  assert string.contains(erlang_fs, "await_input_continue(Parent)")
  assert string.contains(
    erlang_fs,
    "Reader ! {kangaroo_input_continue, self()}",
  )
  assert string.contains(test_worker, "Atomics.compareExchange(childPids")
  assert !string.contains(terminal_ffi, "readSync")
  assert string.contains(terminal_ffi, "receiveMessageOnPort")
  assert fs.exists("src/kangaroo_key_worker.mjs")
  assert fs.exists("src/kangaroo_process_tree.mjs")
  assert string.contains(erlang_isolate, "kangaroo_stderr_table_timeout")
}

pub fn coverage_probe_is_a_downstream_importable_tooling_module_test() {
  let assert Ok(config) = fs.read_file("gleam.toml")
  let assert Ok(workflow) = fs.read_file(".github/workflows/test.yml")
  let assert Ok(architecture) = fs.read_file("ARCHITECTURE.md")
  let assert Ok(contributing) = fs.read_file("CONTRIBUTING.md")

  assert fs.exists("src/kangaroo/coverage_probe.gleam")
  assert !string.contains(config, "internal_modules = [\"kangaroo/*\"]")
  assert string.contains(workflow, "\"kangaroo/coverage_probe\"")
  assert string.contains(architecture, "kangaroo/coverage_probe")
  assert string.contains(architecture, "tooling ABI")
  assert string.contains(contributing, "kangaroo/coverage_probe")
}

pub fn neovim_installation_uses_a_supported_lazy_nvim_spec_test() {
  let assert Ok(readme) = fs.read_file("editors/neovim/README.md")

  assert !string.contains(readme, "subdir =")
  assert string.contains(readme, "vim.opt.rtp:append")
  assert string.contains(readme, "require(\"kangaroo\").setup({")
  assert string.contains(readme, "javascript_runtime = \"nodejs\"")
}

pub fn tui_coverage_is_owned_by_the_original_watch_snapshot_test() {
  let assert Ok(cli) = fs.read_file("src/kangaroo/internal/cli.gleam")
  let cli = string.replace(cli, each: "\r\n", with: "\n")
  let assert [_, coverage] = string.split(cli, "fn run_prepared_tui_coverage(")
  let assert [coverage, ..] = string.split(coverage, "fn finish_tui_coverage(")

  assert string.contains(coverage, "control_process_until_change(")
  assert string.contains(
    coverage,
    "project_dir,\n          roots,\n          baseline,",
  )
  assert string.contains(coverage, "ControlledChildSuperseded")
  assert string.contains(coverage, "coverage superseded")
}
