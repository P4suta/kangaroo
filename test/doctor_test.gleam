import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/doctor.{Check, Failed, Passed, Warning}
import kangaroo/internal/vm

pub fn doctor_compares_prefixed_semantic_versions_test() {
  assert doctor.version_at_least("gleam 1.18.1", "1.18.0")
  assert doctor.version_at_least("v22.0.0", "22.0.0")
  assert !doctor.version_at_least("26.9.9", "27.0.0")
  assert !doctor.version_at_least("unknown", "1.0.0")
}

pub fn doctor_requires_node_with_synchronous_esm_loading_test() {
  assert doctor.minimum_runtime_version("node") == "22.12.0"
  assert doctor.minimum_runtime_version("bun") == "1.4.0"
}

pub fn doctor_rejects_runtime_versions_outside_the_supported_range_test() {
  assert doctor.runtime_version_supported("erlang", "27")
  assert doctor.runtime_version_supported("erlang", "29.9.9")
  assert !doctor.runtime_version_supported("erlang", "26.9.9")
  assert !doctor.runtime_version_supported("erlang", "30.0.0")
  assert doctor.runtime_version_supported("node", "26.0.0")
  assert doctor.runtime_version_supported("bun", "2.0.0")
  assert doctor.runtime_version_supported("deno", "3.0.0")
}

pub fn doctor_renders_fixes_and_returns_exit_two_test() {
  let checks = [
    Check("discovery", Passed, "4 tests", None),
    Check("terminal", Warning, "NO_COLOR is set", None),
    Check(
      "coverage instrumentation",
      Failed,
      "src/broken.gleam cannot be parsed",
      Some("fix the reported Gleam source before running coverage"),
    ),
  ]
  let output = doctor.render(checks)
  assert string.contains(output, "PASS discovery: 4 tests")
  assert string.contains(output, "WARN terminal: NO_COLOR is set")
  assert string.contains(
    output,
    "FAIL coverage instrumentation: src/broken.gleam cannot be parsed",
  )
  assert string.contains(
    output,
    "fix: fix the reported Gleam source before running coverage",
  )
  assert doctor.exit_code(checks) == 2
}

pub fn doctor_reports_exact_source_instrumentation_capability_test() {
  assert doctor.coverage_instrumentation_check(Ok(3))
    == Check(
      "coverage instrumentation",
      Passed,
      "3 Gleam source files can be instrumented exactly",
      None,
    )
  assert doctor.coverage_instrumentation_check(Error(
      "src/broken.gleam: parse error",
    ))
    == Check(
      "coverage instrumentation",
      Failed,
      "src/broken.gleam: parse error",
      Some("fix the reported Gleam source before running coverage"),
    )
}

pub fn doctor_succeeds_when_checks_only_pass_or_warn_test() {
  assert doctor.exit_code([
      Check("runtime", Passed, "Node 24", None),
      Check("colour", Warning, "disabled", None),
    ])
    == 0
}

pub fn doctor_reports_active_runtime_and_operating_system_test() {
  assert vm.runtime_name() != ""
  assert vm.runtime_version() != ""
  assert vm.operating_system() != ""
}
