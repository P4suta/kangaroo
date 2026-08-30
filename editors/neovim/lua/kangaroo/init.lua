local M = {}

local namespace = vim.api.nvim_create_namespace("kangaroo")
local coverage_namespace = vim.api.nvim_create_namespace("kangaroo-coverage")
local sessions = {}
local coverage_processes = {}
local configured = false
local stable_daemon_ms = 10000
local discovery_timeout_ms = 60000
local shutdown_timeout_ms = 6000
local max_protocol_line_bytes = 128 * 1024 * 1024
local max_coverage_error_bytes = 64 * 1024
local restart_delays = { 200, 400, 800, 1600, 3200 }
local configuration = {
  gleam_path = "gleam",
  javascript_runtime = "nodejs",
}
local javascript_runtimes = { nodejs = true, bun = true, deno = true }
local clear_coverage

local function restart_delay(attempt)
  return restart_delays[attempt]
end

local function now_ms()
  local event_loop = vim.uv or vim.loop
  return event_loop.now()
end

local function new_line_decoder(max_line_bytes)
  return {
    fragments = {},
    bytes = 0,
    max_line_bytes = max_line_bytes or max_protocol_line_bytes,
  }
end

local function append_line_fragment(decoder, fragment)
  if fragment == "" then return end
  decoder.bytes = decoder.bytes + #fragment
  if decoder.bytes > decoder.max_line_bytes then
    error(string.format(
      "daemon protocol line exceeded %d bytes",
      decoder.max_line_bytes
    ))
  end
  decoder.fragments[#decoder.fragments + 1] = fragment
end

local function take_lines(decoder, chunk)
  local lines = {}
  local start = 1
  while true do
    local boundary = chunk:find("\n", start, true)
    if boundary == nil then break end
    append_line_fragment(decoder, chunk:sub(start, boundary - 1))
    local line = table.concat(decoder.fragments):gsub("\r$", "")
    decoder.fragments = {}
    decoder.bytes = 0
    if line ~= "" then lines[#lines + 1] = line end
    start = boundary + 1
  end
  append_line_fragment(decoder, chunk:sub(start))
  return lines
end

local function object_record(value)
  return type(value) == "table" and not vim.islist(value)
end

local function exact_fields(value, required, optional)
  if not object_record(value) then return false end
  local allowed = {}
  for _, field in ipairs(required) do allowed[field] = true end
  for _, field in ipairs(optional or {}) do allowed[field] = true end
  for _, field in ipairs(required) do
    if rawget(value, field) == nil then return false end
  end
  for field, _ in pairs(value) do
    if type(field) ~= "string" or not allowed[field] then return false end
  end
  return true
end

local function integer_at_least(value, minimum)
  return type(value) == "number"
    and value == math.floor(value)
    and value >= minimum
end

local function protocol_location(value)
  return exact_fields(value, { "file", "line", "column" })
    and type(value.file) == "string"
    and integer_at_least(value.line, 1)
    and (value.column == vim.NIL or integer_at_least(value.column, 1))
end

local function nullable_location(value)
  return value == vim.NIL or protocol_location(value)
end

local function protocol_failure(value)
  if not object_record(value) or type(value.kind) ~= "string" then return false end
  if value.kind == "equality_mismatch" then
    return exact_fields(
      value,
      { "kind", "expected", "actual", "diff", "location" }
    )
      and type(value.expected) == "string"
      and type(value.actual) == "string"
      and (value.diff == vim.NIL or type(value.diff) == "string")
      and nullable_location(value.location)
  elseif value.kind == "assertion_failed" then
    return exact_fields(value, { "kind", "message", "location" })
      and type(value.message) == "string"
      and nullable_location(value.location)
  elseif value.kind == "unexpected_error" then
    return exact_fields(value, { "kind", "name", "message", "location" })
      and type(value.name) == "string"
      and type(value.message) == "string"
      and nullable_location(value.location)
  end
  return false
end

local function protocol_failures(value)
  if type(value) ~= "table" or not vim.islist(value) then return false end
  for _, failure in ipairs(value) do
    if not protocol_failure(failure) then return false end
  end
  return true
end

local function protocol_outcome(value)
  if not object_record(value) or type(value.kind) ~= "string" then return false end
  if value.kind == "passed" then
    return exact_fields(value, { "kind" })
  elseif value.kind == "skipped" then
    return exact_fields(value, { "kind" }, { "reason" })
      and (value.reason == nil or type(value.reason) == "string")
  elseif value.kind == "flaky" then
    return exact_fields(value, { "kind", "attempts", "failures" })
      and integer_at_least(value.attempts, 2)
      and protocol_failures(value.failures)
  elseif value.kind == "failed" then
    return exact_fields(value, { "kind", "failures" })
      and protocol_failures(value.failures)
  end
  return false
end

local function protocol_summary(value)
  return exact_fields(
    value,
    { "passed", "failed", "skipped", "duration_ms" }
  )
    and integer_at_least(value.passed, 0)
    and integer_at_least(value.failed, 0)
    and integer_at_least(value.skipped, 0)
    and integer_at_least(value.duration_ms, 0)
end

local function protocol_event(value)
  if not object_record(value) or type(value.type) ~= "string" then return false end
  if value.type == "run_started" then
    return exact_fields(value, { "type", "run_id", "case_count" })
      and integer_at_least(value.run_id, -math.huge)
      and integer_at_least(value.case_count, 0)
  elseif value.type == "case_started" then
    return exact_fields(value, { "type", "suite", "case" })
      and type(value.suite) == "string"
      and type(value.case) == "string"
  elseif value.type == "case_output" then
    return exact_fields(
      value,
      { "type", "suite", "case", "stdout", "stderr", "outcome" }
    )
      and type(value.suite) == "string"
      and type(value.case) == "string"
      and type(value.stdout) == "string"
      and type(value.stderr) == "string"
      and protocol_outcome(value.outcome)
  elseif value.type == "case_finished" then
    return exact_fields(
      value,
      { "type", "suite", "case", "outcome", "duration_ms" }
    )
      and type(value.suite) == "string"
      and type(value.case) == "string"
      and protocol_outcome(value.outcome)
      and integer_at_least(value.duration_ms, 0)
  elseif value.type == "suite_started" then
    return exact_fields(value, { "type", "suite" })
      and type(value.suite) == "string"
  elseif value.type == "suite_finished" then
    return exact_fields(value, { "type", "suite", "outcome" })
      and type(value.suite) == "string"
      and protocol_outcome(value.outcome)
  elseif value.type == "run_finished" then
    return exact_fields(value, { "type", "run_id", "summary" })
      and integer_at_least(value.run_id, -math.huge)
      and protocol_summary(value.summary)
  end
  return false
end

local function protocol_test(value)
  local fields = {
    "id", "name", "path", "module", "line", "column", "end_line",
    "end_column", "tags", "timeout_ms", "serial",
  }
  if not exact_fields(value, fields)
    or type(value.id) ~= "string"
    or type(value.name) ~= "string"
    or type(value.path) ~= "string"
    or type(value.module) ~= "string"
    or not integer_at_least(value.line, 1)
    or not integer_at_least(value.column, 1)
    or not integer_at_least(value.end_line, 1)
    or not integer_at_least(value.end_column, 1)
    or type(value.tags) ~= "table"
    or not vim.islist(value.tags)
    or not (value.timeout_ms == vim.NIL
      or integer_at_least(value.timeout_ms, 1))
    or type(value.serial) ~= "boolean" then return false end
  for _, tag in ipairs(value.tags) do
    if type(tag) ~= "string" or not tag:find("%S") then return false end
  end
  return true
end

local function protocol_response(value)
  if not object_record(value)
    or value.protocol_version ~= 1
    or type(value.type) ~= "string" then return false end
  if value.type == "discovered" then
    if not exact_fields(
      value,
      { "protocol_version", "type", "request_id", "tests" }
    )
      or type(value.request_id) ~= "string"
      or type(value.tests) ~= "table"
      or not vim.islist(value.tests) then return false end
    for _, test in ipairs(value.tests) do
      if not protocol_test(test) then return false end
    end
    return true
  elseif value.type == "started" then
    return exact_fields(value, {
      "protocol_version", "type", "request_id", "operation_id", "operation",
    })
      and type(value.request_id) == "string"
      and type(value.operation_id) == "string"
      and (value.operation == "run" or value.operation == "watch")
  elseif value.type == "event" then
    return exact_fields(
      value,
      { "protocol_version", "type", "request_id", "event" }
    )
      and type(value.request_id) == "string"
      and protocol_event(value.event)
  elseif value.type == "completed" then
    return exact_fields(
      value,
      { "protocol_version", "type", "request_id", "exit_code" }
    )
      and type(value.request_id) == "string"
      and integer_at_least(value.exit_code, 0)
      and value.exit_code <= 2
  elseif value.type == "cancelled" then
    return exact_fields(value, {
      "protocol_version", "type", "request_id", "operation_id",
    })
      and type(value.request_id) == "string"
      and type(value.operation_id) == "string"
  elseif value.type == "shutdown" then
    return exact_fields(
      value,
      { "protocol_version", "type", "request_id" }
    ) and type(value.request_id) == "string"
  elseif value.type == "error" then
    return exact_fields(value, {
      "protocol_version", "type", "request_id", "message",
    })
      and type(value.request_id) == "string"
      and type(value.message) == "string"
  end
  return false
end

local function failures_for(event)
  local outcome = event.outcome
  if outcome == nil or (outcome.kind ~= "failed" and outcome.kind ~= "flaky") then
    return {}
  end
  local entries = {}
  for _, failure in ipairs(outcome.failures or {}) do
    local location = failure.location
    if location ~= nil and location.file ~= nil then
      entries[#entries + 1] = {
        test_id = event.case,
        file = location.file,
        lnum = math.max(0, (location.line or 1) - 1),
        col = math.max(0, (location.column or 1) - 1),
        message = failure.message
          or ("expected: " .. (failure.expected or "?")
            .. ", actual: " .. (failure.actual or "?")),
        severity = vim.diagnostic.severity.ERROR,
        source = "kangaroo",
      }
    end
  end
  return entries
end

local function project_root(buffer)
  local name = vim.api.nvim_buf_get_name(buffer or 0)
  local start = name ~= "" and name or vim.fn.getcwd()
  return vim.fs.root(start, { "gleam.toml" }) or vim.fn.getcwd()
end

local function project_target(contents)
  local normalized = tostring(contents):gsub("\r\n", "\n")
  for raw_line in (normalized .. "\n"):gmatch("(.-)\n") do
    local line = raw_line:match("^%s*(.-)%s*$")
    if line ~= "" and not line:match("^#") then
      if line:match("^%[") then return nil end
      local target, trailing = line:match('^target%s*=%s*"([^"]+)"%s*(.*)$')
      if target == nil then
        target, trailing = line:match("^target%s*=%s*'([^']+)'%s*(.*)$")
      end
      if (target == "erlang" or target == "javascript")
        and (trailing == "" or trailing:match("^#")) then
        return target
      end
    end
  end
  return nil
end

local function read_project_target(root)
  local ok, lines = pcall(vim.fn.readfile, root .. "/gleam.toml")
  if not ok then return nil end
  return project_target(table.concat(lines, "\n"))
end

local function invocation_arguments(command, target)
  local arguments = { configuration.gleam_path, "run" }
  if target == "erlang" or target == "javascript" then
    vim.list_extend(arguments, { "--target", target })
  end
  if target == "javascript" then
    vim.list_extend(arguments, {
      "--runtime", configuration.javascript_runtime,
    })
  end
  vim.list_extend(arguments, { "-m", "kangaroo", "--", command })
  return arguments
end

local function daemon_arguments(target)
  return invocation_arguments("daemon", target)
end

local function session_for_current_buffer()
  return sessions[project_root(0)]
end

local function next_id(session, prefix)
  session.request_number = session.request_number + 1
  return prefix .. "-" .. tostring(session.request_number)
end

local function clear_diagnostics(session)
  for bufnr, _ in pairs(session.diagnostic_buffers) do
    vim.diagnostic.reset(namespace, bufnr)
  end
  session.diagnostic_buffers = {}
end

local function operation_started(session, operation_id, command)
  session.active_operations = session.active_operations or {}
  session.operation_order = session.operation_order or {}
  session.operation_states = session.operation_states or {}
  if session.active_operations[operation_id] then return false end
  session.active_operations[operation_id] = true
  session.operation_states[operation_id] = {
    command = command,
    failures = {},
    generation = 0,
    received_run_started = false,
  }
  session.operation_order[#session.operation_order + 1] = operation_id
  return true
end

local function operation_finished(session, operation_id)
  session.active_operations = session.active_operations or {}
  session.operation_order = session.operation_order or {}
  session.operation_states = session.operation_states or {}
  session.active_operations[operation_id] = nil
  session.operation_states[operation_id] = nil
  for index = #session.operation_order, 1, -1 do
    if session.operation_order[index] == operation_id then
      table.remove(session.operation_order, index)
    end
  end
end

local function latest_operation(session)
  session.active_operations = session.active_operations or {}
  session.operation_order = session.operation_order or {}
  for index = #session.operation_order, 1, -1 do
    local operation_id = session.operation_order[index]
    if session.active_operations[operation_id] then return operation_id end
  end
  return nil
end

local function force_stop_job(job_id)
  local ok, pid = pcall(vim.fn.jobpid, job_id)
  if ok and pid ~= nil and pid > 0 then
    if vim.fn.has("win32") == 1 then
      local ok, killer = pcall(vim.system, {
        "taskkill", "/pid", tostring(pid), "/T", "/F",
      }, { detach = true }, function(result)
        if result.code ~= 0 then pcall(vim.fn.jobstop, job_id) end
      end)
      if ok and killer ~= nil then return end
    else
      local event_loop = vim.uv or vim.loop
      pcall(event_loop.kill, -pid, 9)
    end
  end
  pcall(vim.fn.jobstop, job_id)
end

local function begin_operation_generation(session, operation_id)
  local state = session.operation_states[operation_id]
  if state == nil then return end
  session.run_generation = (session.run_generation or 0) + 1
  session.latest_run_generation = session.run_generation
  state.generation = session.run_generation
  state.failures = {}
  session.failures = {}
  session.summary = nil
  clear_diagnostics(session)
end

local function cancel_operation(session, operation_id)
  local state = session.operation_states
    and session.operation_states[operation_id]
  if state == nil or state.cancelled then return false end
  state.cancelled = true
  state.failures = {}
  if state.generation == session.latest_run_generation then
    session.run_generation = (session.run_generation or 0) + 1
    session.latest_run_generation = session.run_generation
    session.failures = {}
    session.summary = nil
    clear_diagnostics(session)
  end
  operation_finished(session, operation_id)
  return true
end

local function request(session, command, fields)
  if session == nil or session.job_id == nil then return nil end
  local message = fields or {}
  message.protocol_version = 1
  message.id = next_id(session, command)
  message.command = command
  vim.fn.chansend(session.job_id, vim.json.encode(message) .. "\n")
  if command == "discover" then
    local request_id = message.id
    local job_id = session.job_id
    session.pending_discovery = request_id
    vim.defer_fn(function()
      if session.stopping
        or session.job_id ~= job_id
        or session.pending_discovery ~= request_id then return end
      session.pending_discovery = nil
      vim.notify(
        "kangaroo: discovery timed out; restarting daemon",
        vim.log.levels.WARN
      )
      force_stop_job(job_id)
    end, discovery_timeout_ms)
  end
  if command == "run" or command == "watch" then
    if operation_started(session, message.id, command) then
      begin_operation_generation(session, message.id)
    end
  end
  return message.id
end

local function rebuild_diagnostics(session)
  clear_diagnostics(session)
  local by_file = {}
  for _, entry in ipairs(session.failures) do
    by_file[entry.file] = by_file[entry.file] or {}
    by_file[entry.file][#by_file[entry.file] + 1] = {
      lnum = entry.lnum,
      col = entry.col,
      end_lnum = entry.lnum,
      end_col = entry.col + 1,
      message = entry.message,
      severity = entry.severity,
      source = entry.source,
    }
  end
  for file, diagnostics in pairs(by_file) do
    local bufnr = vim.fn.bufadd(session.root .. "/" .. file)
    vim.diagnostic.set(namespace, bufnr, diagnostics)
    session.diagnostic_buffers[bufnr] = true
  end
end

local function handle_event(session, operation_id, event)
  session.operation_states = session.operation_states or {}
  local state = session.operation_states[operation_id]
  if state == nil or state.cancelled
    or not session.active_operations[operation_id] then return end
  if event.type == "run_started" then
    if state.generation == 0 or state.received_run_started then
      begin_operation_generation(session, operation_id)
    else
      state.failures = {}
    end
    state.received_run_started = true
  elseif event.type == "case_finished" then
    for _, entry in ipairs(failures_for(event)) do
      state.failures[#state.failures + 1] = entry
    end
  elseif event.type == "run_finished" then
    if state.generation ~= session.latest_run_generation then return end
    session.failures = state.failures
    session.summary = event.summary
    rebuild_diagnostics(session)
    if state.command == "watch" then request(session, "discover") end
  end
end

local function handle_message(session, message)
  if message.protocol_version ~= 1 then return end
  if message.type == "started" then
    local operation_id = message.operation_id or message.request_id
    if operation_started(session, operation_id, message.operation) then
      begin_operation_generation(session, operation_id)
    elseif session.operation_states[operation_id] ~= nil then
      session.operation_states[operation_id].command =
        session.operation_states[operation_id].command or message.operation
    end
  elseif message.type == "completed" then
    operation_finished(session, message.request_id)
  elseif message.type == "cancelled" then
    operation_finished(session, message.operation_id)
  elseif message.type == "event" then
    handle_event(session, message.request_id, message.event or {})
  elseif message.type == "discovered" then
    if session.pending_discovery ~= message.request_id then return end
    session.pending_discovery = nil
    session.tests = message.tests or {}
  elseif message.type == "error" then
    if session.pending_discovery == message.request_id then
      session.pending_discovery = nil
      session.tests = {}
    end
    operation_finished(session, message.request_id)
    vim.schedule(function()
      vim.notify("kangaroo: " .. (message.message or "daemon error"), vim.log.levels.ERROR)
    end)
  end
end

local function stdout_callback(session, data)
  local chunk = table.concat(data or {}, "\n")
  local ok, lines = pcall(take_lines, session.stdout_decoder, chunk)
  if not ok then return false, tostring(lines) end
  for _, line in ipairs(lines) do
    local decoded, message = pcall(vim.json.decode, line)
    if not decoded or type(message) ~= "table" then
      return false, "invalid daemon stdout record"
    end
    if message.protocol_version == 1 then
      if not protocol_response(message) then
        return false, "invalid daemon stdout record"
      end
      handle_message(session, message)
    elseif not integer_at_least(message.protocol_version, -math.huge) then
      return false, "invalid daemon stdout record"
    end
  end
  return true, nil
end

local function alive(session)
  return session ~= nil
    and session.job_id ~= nil
    and vim.fn.jobwait({ session.job_id }, 0)[1] == -1
end

local start_root

local function schedule_restart(session, root, reset_attempts)
  if session.stopping then return end
  if reset_attempts then session.restart_attempt = 0 end
  session.restart_attempt = (session.restart_attempt or 0) + 1
  local delay = restart_delay(session.restart_attempt)
  if delay == nil then
    vim.schedule(function()
      vim.notify(
        "kangaroo: daemon restart limit reached; run :KangarooStart to retry",
        vim.log.levels.ERROR
      )
    end)
    return
  end
  vim.defer_fn(function()
    if not session.stopping then start_root(root, true) end
  end, delay)
end

start_root = function(root, restarting)
  local existing = sessions[root]
  if alive(existing) then return existing end
  local session = existing or {
    root = root,
    request_number = 0,
    stdout_decoder = new_line_decoder(),
    failures = {},
    tests = {},
    diagnostic_buffers = {},
    coverage_buffers = {},
    active_operations = {},
    operation_order = {},
    operation_states = {},
    run_generation = 0,
    latest_run_generation = 0,
    pending_discovery = nil,
    summary = nil,
    stopping = false,
    after_stop = nil,
    restart_attempt = 0,
    started_at_ms = 0,
  }
  sessions[root] = session
  if not restarting then session.restart_attempt = 0 end
  session.stopping = false
  session.stdout_decoder = new_line_decoder()
  session.protocol_failed = false
  session.active_operations = {}
  session.operation_order = {}
  session.operation_states = {}
  session.started_at_ms = now_ms()
  session.target = read_project_target(root)
  session.job_id = vim.fn.jobstart(
    daemon_arguments(session.target),
    {
      cwd = root,
      detach = true,
      stdin = "pipe",
      stdout_buffered = false,
      on_stdout = function(job_id, data)
        if session.job_id ~= job_id or session.stopping
          or session.protocol_failed then return end
        local ok, failure = stdout_callback(session, data)
        if ok then return end
        session.protocol_failed = true
        vim.schedule(function()
          vim.notify("kangaroo: " .. failure, vim.log.levels.ERROR)
        end)
        force_stop_job(job_id)
      end,
      on_stderr = function(job_id, data)
        if session.job_id ~= job_id or session.stopping then return end
        local text = table.concat(data or {}, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        if text ~= "" then
          vim.schedule(function()
            vim.notify("kangaroo: " .. text, vim.log.levels.WARN)
          end)
        end
      end,
      on_exit = function(exited_job_id)
        if session.job_id ~= exited_job_id then return end
        session.job_id = nil
        session.failures = {}
        session.tests = {}
        session.active_operations = {}
        session.operation_order = {}
        session.operation_states = {}
        session.pending_discovery = nil
        session.summary = nil
        clear_diagnostics(session)
        if session.stopping then
          local after_stop = session.after_stop
          session.after_stop = nil
          if after_stop ~= nil then after_stop() end
          return
        end
        local stable = now_ms() - session.started_at_ms >= stable_daemon_ms
        schedule_restart(session, root, stable)
      end,
    }
  )
  if session.job_id <= 0 then
    session.job_id = nil
    vim.notify("kangaroo: could not start daemon", vim.log.levels.ERROR)
    schedule_restart(session, root, false)
    return session
  end
  request(session, "discover")
  request(session, "watch", { selectors = {} })
  return session
end

function M.start()
  return start_root(project_root(0))
end

local function force_stop_system(process)
  if process == nil then return end
  local pid = process.pid
  if pid ~= nil and pid > 0 then
    if vim.fn.has("win32") == 1 then
      local ok, killer = pcall(vim.system, {
        "taskkill", "/pid", tostring(pid), "/T", "/F",
      }, { detach = true }, function(result)
        if result.code ~= 0 and process.kill ~= nil then
          pcall(function() process:kill(9) end)
        end
      end)
      if ok and killer ~= nil then return end
    else
      local event_loop = vim.uv or vim.loop
      local ok, result = pcall(event_loop.kill, -pid, 9)
      if ok and result ~= nil then return end
    end
  end
  if process.kill ~= nil then pcall(function() process:kill(9) end) end
end

local function coverage_owned(root)
  return coverage_processes[root] ~= nil
end

local function claim_coverage(session, entry)
  if coverage_owned(session.root) then return false end
  session.coverage_generation = (session.coverage_generation or 0) + 1
  entry.generation = session.coverage_generation
  coverage_processes[session.root] = entry
  session.coverage_entry = entry
  return true
end

local function release_coverage(session, entry)
  if coverage_processes[session.root] == entry then
    coverage_processes[session.root] = nil
  end
  if session.coverage_entry == entry then session.coverage_entry = nil end
  local after_stop = session.after_coverage_stop
  if after_stop ~= nil and not coverage_owned(session.root) then
    session.after_coverage_stop = nil
    after_stop()
  end
end

local function stop_coverage(session)
  local entry = session.coverage_entry
  if entry == nil or entry.cancelled then return false end
  entry.cancelled = true
  session.coverage_generation = (session.coverage_generation or 0) + 1
  force_stop_system(entry.process)
  return true
end

local function stop_session(session, after_stop)
  if session == nil then return end
  if session.stopping then
    session.after_stop = after_stop
    return
  end
  session.stopping = true
  session.after_stop = after_stop
  local was_alive = alive(session)
  if was_alive then
    request(session, "shutdown")
    local job_id = session.job_id
    pcall(vim.fn.chanclose, job_id, "stdin")
    vim.defer_fn(function()
      if vim.fn.jobwait({ job_id }, 0)[1] == -1 then
        force_stop_job(job_id)
      end
    end, shutdown_timeout_ms)
  end
  if not was_alive then session.job_id = nil end
  session.failures = {}
  session.active_operations = {}
  session.operation_order = {}
  session.operation_states = {}
  session.pending_discovery = nil
  session.summary = nil
  stop_coverage(session)
  clear_diagnostics(session)
  clear_coverage(session)
  if not was_alive and after_stop ~= nil then
    session.after_stop = nil
    after_stop()
  end
end

function M.stop()
  local session = session_for_current_buffer()
  if session ~= nil then
    stop_session(session)
    sessions[session.root] = nil
  end
end

function M.stop_all()
  for _, session in pairs(sessions) do stop_session(session) end
  sessions = {}
end

local function same_path(left, right)
  local normalized_left = vim.fs.normalize(left):gsub("[\\/]$", "")
  local normalized_right = vim.fs.normalize(right):gsub("[\\/]$", "")
  if vim.fn.has("win32") == 1 then
    normalized_left = normalized_left:lower()
    normalized_right = normalized_right:lower()
  end
  return normalized_left == normalized_right
end

local function restart_session(root, session)
  stop_session(session, function()
    if coverage_owned(root) then
      session.after_coverage_stop = function()
        if sessions[root] ~= session then return end
        sessions[root] = nil
        start_root(root)
      end
      return
    end
    if sessions[root] ~= session then return end
    sessions[root] = nil
    start_root(root)
  end)
end

local function restart_for_manifest(filename)
  local absolute = vim.fn.fnamemodify(filename, ":p")
  local manifest_root = vim.fs.dirname(absolute)
  for root, session in pairs(sessions) do
    if same_path(root, manifest_root) then
      restart_session(root, session)
      return true
    end
  end
  return false
end

local function relative_path(root, filename)
  local normal_root = root:gsub("\\", "/"):gsub("/$", "")
  local normal_filename = filename:gsub("\\", "/")
  local prefix = normal_root .. "/"
  local comparable_prefix = prefix
  local comparable_filename = normal_filename
  if normal_root:match("^%a:/") and normal_filename:match("^%a:/") then
    comparable_prefix = prefix:lower()
    comparable_filename = normal_filename:lower()
  end
  return comparable_filename:sub(1, #comparable_prefix) == comparable_prefix
    and normal_filename:sub(#prefix + 1)
    or normal_filename
end

local function select_test(tests, file, line)
  local best = nil
  for _, item in ipairs(tests) do
    local last_line = item.end_line or item.line
    if item.path == file and item.line <= line and line <= last_line then
      if best == nil or item.line > best.line then best = item end
    end
  end
  return best and best.id or nil
end

local function current_selector(session)
  local file = relative_path(session.root, vim.api.nvim_buf_get_name(0))
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return select_test(session.tests, file, line)
end

local function run_selectors(explicit, under_cursor)
  if explicit ~= nil and explicit ~= "" then return { explicit } end
  if under_cursor ~= nil and under_cursor ~= "" then return { under_cursor } end
  return nil
end

function M.run(selector)
  local session = M.start()
  local selectors = run_selectors(selector, current_selector(session))
  if selectors == nil then
    vim.notify(
      "kangaroo: no test under cursor; pass an explicit selector",
      vim.log.levels.INFO
    )
    return
  end
  request(session, "run", { selectors = selectors })
end

function M.run_file()
  local session = M.start()
  local file = relative_path(session.root, vim.api.nvim_buf_get_name(0))
  request(session, "run", { selectors = { file } })
end

function M.cancel()
  local session = session_for_current_buffer()
  if not alive(session) then return end
  local operation_id = latest_operation(session)
  if operation_id == nil then
    vim.notify("kangaroo: no active operation", vim.log.levels.INFO)
    return
  end
  if not cancel_operation(session, operation_id) then return end
  request(session, "cancel", { operation_id = operation_id })
end

function M.pick()
  local session = M.start()
  vim.ui.select(session.tests, {
    prompt = "Kangaroo tests",
    format_item = function(item) return item.id end,
  }, function(item)
    if item then M.run(item.id) end
  end)
end

function M.quickfix()
  local session = session_for_current_buffer()
  local items = {}
  for _, entry in ipairs(session and session.failures or {}) do
    items[#items + 1] = {
      filename = session.root .. "/" .. entry.file,
      lnum = entry.lnum + 1,
      col = entry.col + 1,
      text = entry.message,
    }
  end
  vim.fn.setqflist({}, "r", { items = items, title = "Kangaroo" })
  if #items > 0 then vim.cmd("copen")
  else vim.notify("kangaroo: no failures", vim.log.levels.INFO) end
end

function M.status()
  local session = session_for_current_buffer()
  local summary = session and session.summary or nil
  if summary == nil then
    vim.notify("kangaroo: no run yet", vim.log.levels.INFO)
    return
  end
  vim.notify(string.format(
    "kangaroo: %d passed, %d failed, %d skipped (in %dms)",
    summary.passed, summary.failed, summary.skipped, summary.duration_ms
  ), summary.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

clear_coverage = function(session)
  for bufnr, _ in pairs(session.coverage_buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, coverage_namespace, 0, -1)
    end
  end
  session.coverage_buffers = {}
end

local function coverage_filename(root, source)
  local normalized = source:gsub("\\", "/")
  if normalized:match("^/") or normalized:match("^%a:/") then return normalized end
  return root:gsub("[\\/]$", "") .. "/" .. normalized
end

local function apply_lcov(session, contents)
  clear_coverage(session)
  local source = nil
  local buffers = {}
  for line in contents:gmatch("[^\n]+") do
    local file = line:match("^SF:(.+)$")
    if file then
      source = file
      local bufnr = vim.fn.bufadd(coverage_filename(session.root, source))
      vim.api.nvim_buf_clear_namespace(bufnr, coverage_namespace, 0, -1)
      buffers[bufnr] = true
    end
    local number, hits = line:match("^DA:(%d+),(%d+)")
    if source and number then
      local bufnr = vim.fn.bufadd(coverage_filename(session.root, source))
      vim.api.nvim_buf_set_extmark(bufnr, coverage_namespace, tonumber(number) - 1, 0, {
        sign_text = tonumber(hits) > 0 and "▌" or "▏",
        sign_hl_group = tonumber(hits) > 0 and "DiagnosticOk" or "DiagnosticError",
      })
      buffers[bufnr] = true
    end
  end
  session.coverage_buffers = buffers
end

local function coverage_arguments(target)
  local arguments = invocation_arguments("coverage", target)
  vim.list_extend(arguments, { "--coverage-reporter", "lcov" })
  return arguments
end

local function coverage_options(root, on_stderr)
  return {
    cwd = root,
    text = true,
    detach = true,
    stdout = function() end,
    stderr = on_stderr or function() end,
  }
end

local function coverage_result_is_publishable(code)
  return code == 0 or code == 1
end

function M.coverage()
  local session = M.start()
  local entry = { cancelled = false, process = nil }
  if not claim_coverage(session, entry) then
    vim.notify(
      "kangaroo: coverage is already running or stopping for this package",
      vim.log.levels.INFO
    )
    return false
  end

  local stderr_tail = ""
  local function capture_stderr(_, data)
    if data == nil then return end
    stderr_tail = stderr_tail .. tostring(data)
    if #stderr_tail > max_coverage_error_bytes then
      stderr_tail = stderr_tail:sub(#stderr_tail - max_coverage_error_bytes + 1)
    end
  end
  local function completed(result)
    release_coverage(session, entry)
    vim.schedule(function()
      if entry.cancelled
        or sessions[session.root] ~= session
        or session.coverage_generation ~= entry.generation then return end
      if not coverage_result_is_publishable(result.code) then
        local detail = stderr_tail:gsub("^%s+", ""):gsub("%s+$", "")
        if detail == "" then
          detail = "process exited with code " .. tostring(result.code)
        end
        vim.notify("kangaroo coverage: " .. detail, vim.log.levels.ERROR)
        return
      end
      local path = session.root .. "/coverage/lcov.info"
      local ok, lines = pcall(vim.fn.readfile, path)
      if not ok then
        vim.notify(
          "kangaroo coverage: could not read coverage/lcov.info",
          vim.log.levels.ERROR
        )
        return
      end
      apply_lcov(session, table.concat(lines, "\n"))
      if result.code == 1 then
        vim.notify(
          "kangaroo coverage: results include a test failure, flaky test, or threshold violation",
          vim.log.levels.WARN
        )
      end
    end)
  end
  local ok, process = pcall(
    vim.system,
    coverage_arguments(session.target),
    coverage_options(session.root, capture_stderr),
    completed
  )
  if not ok then
    entry.cancelled = true
    release_coverage(session, entry)
    vim.notify(
      "kangaroo coverage: could not start process: " .. tostring(process),
      vim.log.levels.ERROR
    )
    return false
  end
  entry.process = process
  return true
end

function M.birdie()
  vim.cmd(
    "botright split | terminal "
      .. vim.fn.shellescape(configuration.gleam_path)
      .. " run -m birdie"
  )
end

local function apply_configuration(options)
  if options == nil then return false end
  if type(options) ~= "table" then
    error("kangaroo: setup options must be a table")
  end
  for key, _ in pairs(options) do
    if key ~= "gleam_path" and key ~= "javascript_runtime" then
      error("kangaroo: unknown setup option: " .. tostring(key))
    end
  end
  local gleam_path = options.gleam_path
  if gleam_path == nil then gleam_path = configuration.gleam_path end
  local runtime = options.javascript_runtime
  if runtime == nil then runtime = configuration.javascript_runtime end
  if type(gleam_path) ~= "string" or gleam_path == "" then
    error("kangaroo: gleam_path must be a non-empty string")
  end
  if not javascript_runtimes[runtime] then
    error("kangaroo: javascript_runtime must be nodejs, bun, or deno")
  end
  local changed = configuration.gleam_path ~= gleam_path
    or configuration.javascript_runtime ~= runtime
  configuration.gleam_path = gleam_path
  configuration.javascript_runtime = runtime
  return changed
end

function M.setup(options)
  local changed = apply_configuration(options)
  if changed then
    for root, session in pairs(sessions) do
      restart_session(root, session)
    end
  end
  if configured then return end
  configured = true
  vim.api.nvim_create_user_command("KangarooStart", M.start, {})
  vim.api.nvim_create_user_command("KangarooStop", M.stop, {})
  vim.api.nvim_create_user_command("KangarooRun", function(options) M.run(options.args) end, { nargs = "?" })
  vim.api.nvim_create_user_command("KangarooRunFile", M.run_file, {})
  vim.api.nvim_create_user_command("KangarooCancel", M.cancel, {})
  vim.api.nvim_create_user_command("KangarooTests", M.pick, {})
  vim.api.nvim_create_user_command("KangarooQuickfix", M.quickfix, {})
  vim.api.nvim_create_user_command("KangarooStatus", M.status, {})
  vim.api.nvim_create_user_command("KangarooCoverage", M.coverage, {})
  vim.api.nvim_create_user_command("KangarooBirdie", M.birdie, {})
  local manifest_group = vim.api.nvim_create_augroup(
    "kangaroo-manifest",
    { clear = true }
  )
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = manifest_group,
    pattern = "gleam.toml",
    callback = function(event)
      local filename = vim.api.nvim_buf_get_name(event.buf)
      restart_for_manifest(filename ~= "" and filename or event.file)
    end,
    desc = "Restart Kangaroo when the package target changes",
  })
end

M._test = {
  apply_lcov = apply_lcov,
  apply_configuration = apply_configuration,
  begin_operation_generation = begin_operation_generation,
  cancel_operation = cancel_operation,
  claim_coverage = claim_coverage,
  coverage_arguments = coverage_arguments,
  coverage_options = coverage_options,
  coverage_result_is_publishable = coverage_result_is_publishable,
  coverage_namespace = coverage_namespace,
  coverage_owned = coverage_owned,
  failures_for = failures_for,
  force_stop_job = force_stop_job,
  force_stop_system = force_stop_system,
  handle_message = handle_message,
  daemon_arguments = daemon_arguments,
  latest_operation = latest_operation,
  new_line_decoder = new_line_decoder,
  operation_finished = operation_finished,
  operation_started = operation_started,
  protocol_response = protocol_response,
  relative_path = relative_path,
  project_target = project_target,
  request = request,
  release_coverage = release_coverage,
  restart_delay = restart_delay,
  restart_for_manifest = restart_for_manifest,
  run_selectors = run_selectors,
  select_test = select_test,
  start_root = start_root,
  stop_coverage = stop_coverage,
  stdout_callback = stdout_callback,
  take_lines = take_lines,
}

return M
