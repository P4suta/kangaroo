local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local kangaroo = require("kangaroo")
local test = kangaroo._test

local lines, remainder = test.take_lines("", '{"a":1}\n{"b"')
assert(vim.deep_equal(lines, { '{"a":1}' }))
lines, remainder = test.take_lines(remainder, ':2}\n')
assert(vim.deep_equal(lines, { '{"b":2}' }))
assert(remainder == "")

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

local operations = { active_operations = {}, operation_order = {} }
test.operation_started(operations, "watch-1")
test.operation_started(operations, "run-2")
assert(test.latest_operation(operations) == "run-2")
test.operation_finished(operations, "run-2")
assert(test.latest_operation(operations) == "watch-1")
test.operation_finished(operations, "watch-1")
assert(test.latest_operation(operations) == nil)

local missing_job = { job_id = nil, request_number = 0 }
local request_ok, request_id = pcall(test.request, missing_job, "run", {})
assert(request_ok)
assert(request_id == nil)

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
local original_defer_fn = vim.defer_fn
local original_diagnostic_reset = vim.diagnostic.reset
local jobs = {}
local writes = {}
local deferred = {}
local resets = {}
local running = {}
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
vim.defer_fn = function(callback, delay)
  deferred[#deferred + 1] = { callback = callback, delay = delay }
end
vim.diagnostic.reset = function(_, bufnr) resets[#resets + 1] = bufnr end

local ok, lifecycle_error = pcall(function()
  local session = test.start_root("/tmp/kangaroo-nvim-crash-test")
  assert(#jobs == 1)
  assert(vim.deep_equal(jobs[1].command,
    { "gleam", "run", "-m", "kangaroo", "--", "daemon" }))
  assert(vim.json.decode(writes[1].contents).command == "discover")
  assert(vim.json.decode(writes[2].contents).command == "watch")
  assert(test.latest_operation(session):match("^watch%-"))

  session.failures = { { message = "stale" } }
  session.diagnostic_buffers[77] = true
  running[jobs[1].id] = false
  jobs[1].options.on_exit()
  assert(#session.failures == 0)
  assert(test.latest_operation(session) == nil)
  assert(vim.deep_equal(resets, { 77 }))
  assert(#deferred == 1 and deferred[1].delay == 200)

  deferred[1].callback()
  assert(#jobs == 2)
  assert(vim.json.decode(writes[3].contents).command == "discover")
  assert(vim.json.decode(writes[4].contents).command == "watch")
end)

kangaroo.stop_all()
vim.fn.jobstart = original_jobstart
vim.fn.jobwait = original_jobwait
vim.fn.chansend = original_chansend
vim.defer_fn = original_defer_fn
vim.diagnostic.reset = original_diagnostic_reset
assert(ok, lifecycle_error)

print("kangaroo.nvim headless tests passed")
