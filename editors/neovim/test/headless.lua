local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local kangaroo = require("kangaroo")
local test = kangaroo._test

local decoder = test.new_line_decoder()
local lines = test.take_lines(decoder, '{"a":1}\n{"b"')
assert(vim.deep_equal(lines, { '{"a":1}' }))
lines = test.take_lines(decoder, ':2}\n')
assert(vim.deep_equal(lines, { '{"b":2}' }))
assert(decoder.bytes == 0)
assert(#decoder.fragments == 0)

local bounded_decoder = test.new_line_decoder(8)
assert(vim.deep_equal(test.take_lines(bounded_decoder, "12"), {}))
assert(vim.deep_equal(test.take_lines(bounded_decoder, "34"), {}))
assert(table.concat(bounded_decoder.fragments) == "1234")
local bounded, bounded_error = pcall(function()
  test.take_lines(bounded_decoder, "56789")
end)
assert(not bounded and bounded_error:match("exceeded 8 bytes"))

local invalid_stdout = {
  stdout_decoder = test.new_line_decoder(),
}
local valid_protocol, protocol_error = test.stdout_callback(
  invalid_stdout,
  { "not-json", "" }
)
assert(not valid_protocol and protocol_error:match("invalid daemon stdout"))

local invalid_shape = {
  stdout_decoder = test.new_line_decoder(),
}
local valid_shape, shape_error = test.stdout_callback(invalid_shape, {
  '{"protocol_version":1,"type":"discovered","request_id":"discover-1","tests":"invalid"}',
  "",
})
assert(not valid_shape and shape_error:match("invalid daemon stdout record"))

local failures = test.failures_for({
  case = "test/math.gleam::addition_test",
  outcome = {
    kind = "failed",
    failures = {{
      message = "boom",
      location = { file = "test/math.gleam", line = 7, column = 2 },
    }},
  },
})
assert(failures[1].lnum == 6)
assert(failures[1].col == 1)

assert(vim.deep_equal(test.coverage_arguments(), {
  "gleam", "run", "-m", "kangaroo", "--", "coverage",
  "--coverage-reporter", "lcov",
}))
assert(test.project_target(
  'name = "demo"\r\ntarget = "javascript" # explicit runtime\r\n\r\n[tools.kangaroo]\r\n'
) == "javascript")
assert(test.project_target(
  'name = "demo"\n\n[javascript]\ntarget = "javascript"\n'
) == nil)
assert(vim.deep_equal(test.daemon_arguments("javascript"), {
  "gleam", "run", "--target", "javascript", "--runtime", "nodejs",
  "-m", "kangaroo", "--", "daemon",
}))
test.apply_configuration({
  gleam_path = "/tools/gleam",
  javascript_runtime = "bun",
})
assert(vim.deep_equal(test.coverage_arguments("javascript"), {
  "/tools/gleam", "run", "--target", "javascript", "--runtime", "bun",
  "-m", "kangaroo", "--", "coverage", "--coverage-reporter", "lcov",
}))
local valid_runtime, runtime_error = pcall(function()
  test.apply_configuration({ javascript_runtime = "unknown" })
end)
assert(not valid_runtime and runtime_error:match("nodejs, bun, or deno"))
local valid_key, key_error = pcall(function()
  test.apply_configuration({ typo = true })
end)
assert(not valid_key and key_error:match("unknown setup option"))
local valid_path, path_error = pcall(function()
  test.apply_configuration({ gleam_path = false })
end)
assert(not valid_path and path_error:match("non%-empty string"))
test.apply_configuration({
  gleam_path = "gleam",
  javascript_runtime = "nodejs",
})
assert(test.coverage_options("/tmp/package").detach == true)

assert(test.restart_delay(1) == 200)
assert(test.restart_delay(2) == 400)
assert(test.restart_delay(5) == 3200)
assert(test.restart_delay(6) == nil)

assert(test.relative_path("C:\\work\\pkg", "c:\\work\\pkg\\test\\math.gleam")
  == "test/math.gleam")

local selected = test.select_test({
  { id = "first", path = "test/math.gleam", line = 2, end_line = 4 },
  { id = "second", path = "test/math.gleam", line = 10, end_line = 12 },
}, "test/math.gleam", 8)
assert(selected == nil)
selected = test.select_test({
  { id = "first", path = "test/math.gleam", line = 2, end_line = 4 },
  { id = "second", path = "test/math.gleam", line = 10, end_line = 12 },
}, "test/math.gleam", 11)
assert(selected == "second")

assert(vim.deep_equal(
  test.run_selectors("test/math.gleam::addition_test", nil),
  { "test/math.gleam::addition_test" }
))
assert(vim.deep_equal(
  test.run_selectors("", "test/math.gleam::cursor_test"),
  { "test/math.gleam::cursor_test" }
))
assert(test.run_selectors(nil, nil) == nil)

local killed_signal = nil
local coverage_process = {
  kill = function(_, signal) killed_signal = signal end,
}
local coverage_lifecycle = {
  root = "/tmp/kangaroo-nvim-coverage-owner",
  coverage_generation = 3,
}
local coverage_entry = { process = coverage_process, cancelled = false }
assert(test.claim_coverage(coverage_lifecycle, coverage_entry))
assert(test.coverage_owned(coverage_lifecycle.root))
local competing_coverage = {
  root = coverage_lifecycle.root,
  coverage_generation = 0,
}
assert(not test.claim_coverage(competing_coverage, { cancelled = false }))
assert(test.stop_coverage(coverage_lifecycle))
assert(killed_signal == 9)
assert(coverage_lifecycle.coverage_entry == coverage_entry)
assert(test.coverage_owned(coverage_lifecycle.root))
assert(not test.claim_coverage(competing_coverage, { cancelled = false }))
test.release_coverage(coverage_lifecycle, coverage_entry)
assert(not test.coverage_owned(coverage_lifecycle.root))
local next_entry = { cancelled = false }
assert(test.claim_coverage(competing_coverage, next_entry))
test.release_coverage(competing_coverage, next_entry)
assert(not test.stop_coverage({ root = "/tmp/no-coverage" }))
assert(test.coverage_options("/tmp/package").stdout ~= nil)
assert(test.coverage_options("/tmp/package").stderr ~= nil)
assert(test.coverage_result_is_publishable(0))
assert(test.coverage_result_is_publishable(1))
assert(not test.coverage_result_is_publishable(2))

local discoveries = {
  pending_discovery = "discover-new",
  tests = {{ id = "current" }},
}
test.handle_message(discoveries, {
  protocol_version = 1,
  type = "discovered",
  request_id = "discover-old",
  tests = {{ id = "stale" }},
})
assert(discoveries.tests[1].id == "current")
test.handle_message(discoveries, {
  protocol_version = 1,
  type = "discovered",
  request_id = "discover-new",
  tests = {{ id = "newest" }},
})
assert(discoveries.tests[1].id == "newest")
discoveries.pending_discovery = "discover-error"
test.handle_message(discoveries, {
  protocol_version = 1,
  type = "error",
  request_id = "discover-error",
  message = "source could not be parsed",
})
assert(#discoveries.tests == 0)

local operations = { active_operations = {}, operation_order = {} }
test.operation_started(operations, "watch-1", "watch")
assert(operations.operation_states["watch-1"].command == "watch")
test.operation_started(operations, "run-2")
assert(test.latest_operation(operations) == "run-2")
test.operation_finished(operations, "run-2")
assert(test.latest_operation(operations) == "watch-1")
test.operation_finished(operations, "watch-1")
assert(test.latest_operation(operations) == nil)

local concurrent = {
  root = "/tmp/kangaroo-nvim-concurrent",
  failures = {},
  summary = nil,
  diagnostic_buffers = {},
  active_operations = {},
  operation_order = {},
  operation_states = {},
  run_generation = 0,
  latest_run_generation = 0,
}
local function message(request_id, message_type, fields)
  local value = fields or {}
  value.protocol_version = 1
  value.request_id = request_id
  value.type = message_type
  test.handle_message(concurrent, value)
end
message("old", "started", { operation_id = "old" })
message("old", "event", { event = { type = "run_started" } })
message("old", "event", { event = {
  type = "case_finished",
  case = "test/math.gleam::old_test",
  outcome = { kind = "failed", failures = {{
    message = "old failure",
    location = { file = "test/math.gleam", line = 1, column = 1 },
  }}},
} })
message("new", "started", { operation_id = "new" })
message("new", "event", { event = { type = "run_started" } })
message("old", "event", { event = {
  type = "run_finished",
  summary = { passed = 0, failed = 1, skipped = 0, duration_ms = 1 },
} })
assert(concurrent.summary == nil)
assert(#concurrent.failures == 0)
message("new", "event", { event = {
  type = "run_finished",
  summary = { passed = 1, failed = 0, skipped = 0, duration_ms = 1 },
} })
assert(concurrent.summary.passed == 1)
assert(concurrent.summary.failed == 0)

local delayed_start = {
  root = "/tmp/kangaroo-nvim-delayed-start",
  failures = {},
  summary = nil,
  diagnostic_buffers = {},
  active_operations = {},
  operation_order = {},
  operation_states = {},
  run_generation = 0,
  latest_run_generation = 0,
}
test.handle_message(delayed_start, {
  protocol_version = 1,
  type = "started",
  request_id = "old",
  operation_id = "old",
})
test.handle_message(delayed_start, {
  protocol_version = 1,
  type = "started",
  request_id = "new",
  operation_id = "new",
})
test.handle_message(delayed_start, {
  protocol_version = 1,
  type = "event",
  request_id = "old",
  event = { type = "run_started" },
})
test.handle_message(delayed_start, {
  protocol_version = 1,
  type = "event",
  request_id = "old",
  event = {
    type = "run_finished",
    summary = { passed = 0, failed = 1, skipped = 0, duration_ms = 1 },
  },
})
assert(delayed_start.summary == nil)
test.handle_message(delayed_start, {
  protocol_version = 1,
  type = "event",
  request_id = "new",
  event = { type = "run_started" },
})
test.handle_message(delayed_start, {
  protocol_version = 1,
  type = "event",
  request_id = "new",
  event = {
    type = "run_finished",
    summary = { passed = 1, failed = 0, skipped = 0, duration_ms = 1 },
  },
})
assert(delayed_start.summary.passed == 1)

local requested = {
  failures = { { message = "stale" } },
  summary = { passed = 1 },
  diagnostic_buffers = {},
  active_operations = {},
  operation_order = {},
  operation_states = {},
  run_generation = 0,
  latest_run_generation = 0,
}
test.operation_started(requested, "run-requested")
test.begin_operation_generation(requested, "run-requested")
assert(#requested.failures == 0)
assert(requested.summary == nil)
assert(requested.latest_run_generation == 1)

local cancelled = {
  failures = { { message = "published before cancellation" } },
  summary = { passed = 1 },
  diagnostic_buffers = {},
  active_operations = {},
  operation_order = {},
  operation_states = {},
  run_generation = 0,
  latest_run_generation = 0,
}
test.operation_started(cancelled, "watch-cancelled")
test.begin_operation_generation(cancelled, "watch-cancelled")
assert(test.cancel_operation(cancelled, "watch-cancelled"))
assert(test.latest_operation(cancelled) == nil)
test.handle_message(cancelled, {
  protocol_version = 1,
  type = "event",
  request_id = "watch-cancelled",
  event = {
    type = "run_finished",
    summary = { passed = 0, failed = 1, skipped = 0, duration_ms = 1 },
  },
})
assert(cancelled.summary == nil)
assert(#cancelled.failures == 0)

test.handle_message(cancelled, {
  protocol_version = 1,
  type = "event",
  request_id = "unknown-operation",
  event = {
    type = "run_finished",
    summary = { passed = 99, failed = 0, skipped = 0, duration_ms = 1 },
  },
})
assert(cancelled.summary == nil)

local missing_job = { job_id = nil, request_number = 0 }
local request_ok, request_id = pcall(test.request, missing_job, "run", {})
assert(request_ok)
assert(request_id == nil)

local original_has = vim.fn.has
local original_jobpid = vim.fn.jobpid
local original_jobstop_for_taskkill = vim.fn.jobstop
local original_system = vim.system
local taskkill_callback
local taskkill_stopped = {}
vim.fn.has = function(feature)
  if feature == "win32" then return 1 end
  return original_has(feature)
end
vim.fn.jobpid = function() return 4242 end
vim.fn.jobstop = function(job_id)
  taskkill_stopped[#taskkill_stopped + 1] = job_id
  return 1
end
vim.system = function(command, options, callback)
  assert(vim.deep_equal(command,
    { "taskkill", "/pid", "4242", "/T", "/F" }))
  assert(options.detach == true)
  taskkill_callback = callback
  return {}
end
test.force_stop_job(77)
assert(#taskkill_stopped == 0)
taskkill_callback({ code = 1 })
assert(vim.deep_equal(taskkill_stopped, { 77 }))
vim.fn.has = original_has
vim.fn.jobpid = original_jobpid
vim.fn.jobstop = original_jobstop_for_taskkill
vim.system = original_system

local coverage_session = {
  root = "/tmp/kangaroo-nvim-test",
  coverage_buffers = {},
}
test.apply_lcov(coverage_session,
  "SF:src/current.gleam\nDA:1,1\nend_of_record\n"
    .. "SF:src/stale.gleam\nDA:2,0\nend_of_record\n")
local stale_buffer = vim.fn.bufadd(coverage_session.root .. "/src/stale.gleam")
assert(#vim.api.nvim_buf_get_extmarks(
  stale_buffer, test.coverage_namespace, 0, -1, {}
) == 1)
test.apply_lcov(coverage_session,
  "SF:src/current.gleam\nDA:1,0\nend_of_record\n")
assert(#vim.api.nvim_buf_get_extmarks(
  stale_buffer, test.coverage_namespace, 0, -1, {}
) == 0)

local original_jobstart = vim.fn.jobstart
local original_jobwait = vim.fn.jobwait
local original_chansend = vim.fn.chansend
local original_jobstop = vim.fn.jobstop
local original_defer_fn = vim.defer_fn
local original_diagnostic_reset = vim.diagnostic.reset
local jobs = {}
local writes = {}
local deferred = {}
local resets = {}
local running = {}
local stopped = {}
local stopped_coverage_buffer = nil
vim.fn.jobstart = function(command, options)
  local id = 100 + #jobs + 1
  jobs[#jobs + 1] = { id = id, command = command, options = options }
  running[id] = true
  return id
end
vim.fn.jobwait = function(ids)
  return { running[ids[1]] and -1 or 0 }
end
vim.fn.chansend = function(job_id, contents)
  writes[#writes + 1] = { job_id = job_id, contents = contents }
  return #contents
end
vim.fn.jobstop = function(job_id)
  stopped[#stopped + 1] = job_id
  running[job_id] = false
  return 1
end
vim.defer_fn = function(callback, delay)
  deferred[#deferred + 1] = { callback = callback, delay = delay }
end
vim.diagnostic.reset = function(_, bufnr) resets[#resets + 1] = bufnr end

local ok, lifecycle_error = pcall(function()
  local session = test.start_root("/tmp/kangaroo-nvim-crash-test")
  assert(#jobs == 1)
  assert(vim.deep_equal(jobs[1].command,
    { "gleam", "run", "-m", "kangaroo", "--", "daemon" }))
  assert(jobs[1].options.detach == true)
  assert(vim.json.decode(writes[1].contents).command == "discover")
  assert(vim.json.decode(writes[2].contents).command == "watch")
  assert(test.latest_operation(session):match("^watch%-"))
  assert(#deferred == 1 and deferred[1].delay == 60000)

  session.failures = { { message = "stale" } }
  session.tests = { { id = "stale" } }
  session.summary = { passed = 9, failed = 0, skipped = 0, duration_ms = 1 }
  session.diagnostic_buffers[77] = true
  deferred[1].callback()
  assert(vim.deep_equal(stopped, { jobs[1].id }))
  jobs[1].options.on_exit(jobs[1].id)
  assert(#session.failures == 0)
  assert(#session.tests == 0)
  assert(session.summary == nil)
  assert(test.latest_operation(session) == nil)
  assert(vim.deep_equal(resets, { 77 }))
  assert(#deferred == 2 and deferred[2].delay == 200)

  deferred[2].callback()
  assert(#jobs == 2)
  assert(vim.json.decode(writes[3].contents).command == "discover")
  assert(vim.json.decode(writes[4].contents).command == "watch")
  assert(#deferred == 3 and deferred[3].delay == 60000)

  session.tests = {}
  jobs[1].options.on_stdout(jobs[1].id, {
    vim.json.encode({
      protocol_version = 1,
      type = "discovered",
      request_id = "stale",
      tests = {{ id = "stale" }},
    }),
    "",
  })
  assert(#session.tests == 0)

  jobs[2].options.on_stdout(jobs[2].id, {
    vim.json.encode({
      protocol_version = 1,
      type = "discovered",
      request_id = vim.json.decode(writes[3].contents).id,
      tests = {},
    }),
    "",
  })
  deferred[3].callback()
  assert(#stopped == 1)

  session.restart_attempt = 5
  running[jobs[2].id] = false
  jobs[2].options.on_exit(jobs[2].id)
  assert(#deferred == 3)

  local manifest_root = "/tmp/kangaroo-nvim-manifest-test"
  local manifest_session = test.start_root(manifest_root)
  local coverage_killed = false
  local coverage_entry = {
    cancelled = false,
    process = {
      kill = function(_, signal)
        coverage_killed = signal == 9
      end,
    },
  }
  assert(test.claim_coverage(manifest_session, coverage_entry))
  assert(#jobs == 3)
  assert(test.restart_for_manifest(manifest_root .. "/gleam.toml"))
  assert(#jobs == 3)
  assert(coverage_killed)
  assert(vim.json.decode(writes[#writes].contents).command == "shutdown")
  running[jobs[3].id] = false
  jobs[3].options.on_exit(jobs[3].id)
  assert(#jobs == 3)
  test.release_coverage(manifest_session, coverage_entry)
  assert(#jobs == 4)

  test.apply_lcov(session,
    "SF:src/stopped.gleam\nDA:1,1\nend_of_record\n")
  stopped_coverage_buffer = vim.fn.bufadd(
    session.root .. "/src/stopped.gleam"
  )
  assert(#vim.api.nvim_buf_get_extmarks(
    stopped_coverage_buffer, test.coverage_namespace, 0, -1, {}
  ) == 1)
end)

kangaroo.stop_all()
assert(#vim.api.nvim_buf_get_extmarks(
  stopped_coverage_buffer, test.coverage_namespace, 0, -1, {}
) == 0)
vim.fn.jobstart = original_jobstart
vim.fn.jobwait = original_jobwait
vim.fn.chansend = original_chansend
vim.fn.jobstop = original_jobstop
vim.defer_fn = original_defer_fn
vim.diagnostic.reset = original_diagnostic_reset
assert(ok, lifecycle_error)

kangaroo.setup()
local manifest_autocmds = vim.api.nvim_get_autocmds({
  group = "kangaroo-manifest",
  event = "BufWritePost",
})
assert(#manifest_autocmds == 1)
assert(manifest_autocmds[1].pattern == "gleam.toml")

print("kangaroo.nvim headless tests passed")
