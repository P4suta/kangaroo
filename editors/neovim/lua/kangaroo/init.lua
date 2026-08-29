local M = {}

local namespace = vim.api.nvim_create_namespace("kangaroo")
local coverage_namespace = vim.api.nvim_create_namespace("kangaroo-coverage")
local sessions = {}
local configured = false

local function take_lines(remainder, chunk)
  local buffer = remainder .. chunk
  local lines = {}
  while true do
    local boundary = buffer:find("\n", 1, true)
    if boundary == nil then break end
    local line = buffer:sub(1, boundary - 1):gsub("\r$", "")
    buffer = buffer:sub(boundary + 1)
    if line ~= "" then lines[#lines + 1] = line end
  end
  return lines, buffer
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

local function session_for_current_buffer()
  return sessions[project_root(0)]
end

local function next_id(session, prefix)
  session.request_number = session.request_number + 1
  return prefix .. "-" .. tostring(session.request_number)
end

local function operation_started(session, operation_id)
  session.active_operations = session.active_operations or {}
  session.operation_order = session.operation_order or {}
  if session.active_operations[operation_id] then return end
  session.active_operations[operation_id] = true
  session.operation_order[#session.operation_order + 1] = operation_id
end

local function operation_finished(session, operation_id)
  session.active_operations = session.active_operations or {}
  session.operation_order = session.operation_order or {}
  session.active_operations[operation_id] = nil
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

local function request(session, command, fields)
  local message = fields or {}
  message.protocol_version = 1
  message.id = next_id(session, command)
  message.command = command
  vim.fn.chansend(session.job_id, vim.json.encode(message) .. "\n")
  if command == "run" or command == "watch" then
    operation_started(session, message.id)
  end
  return message.id
end

local function clear_diagnostics(session)
  for bufnr, _ in pairs(session.diagnostic_buffers) do
    vim.diagnostic.reset(namespace, bufnr)
  end
  session.diagnostic_buffers = {}
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

local function handle_event(session, event)
  if event.type == "run_started" then
    session.failures = {}
    clear_diagnostics(session)
  elseif event.type == "case_finished" then
    for _, entry in ipairs(failures_for(event)) do
      session.failures[#session.failures + 1] = entry
    end
  elseif event.type == "run_finished" then
    session.summary = event.summary
    rebuild_diagnostics(session)
  end
end

local function handle_message(session, message)
  if message.protocol_version ~= 1 then return end
  if message.type == "started" then
    operation_started(session, message.operation_id or message.request_id)
  elseif message.type == "completed" then
    operation_finished(session, message.request_id)
  elseif message.type == "cancelled" then
    operation_finished(session, message.operation_id)
  elseif message.type == "event" then
    handle_event(session, message.event or {})
  elseif message.type == "discovered" then
    session.tests = message.tests or {}
  elseif message.type == "error" then
    operation_finished(session, message.request_id)
    vim.schedule(function()
      vim.notify("kangaroo: " .. (message.message or "daemon error"), vim.log.levels.ERROR)
    end)
  end
end

local function stdout_callback(session, data)
  local chunk = table.concat(data or {}, "\n")
  local lines
  lines, session.stdout_remainder = take_lines(session.stdout_remainder, chunk)
  for _, line in ipairs(lines) do
    local ok, message = pcall(vim.json.decode, line)
    if ok and type(message) == "table" then
      handle_message(session, message)
    end
  end
end

local function alive(session)
  return session ~= nil
    and session.job_id ~= nil
    and vim.fn.jobwait({ session.job_id }, 0)[1] == -1
end

local function start_root(root)
  local existing = sessions[root]
  if alive(existing) then return existing end
  local session = existing or {
    root = root,
    request_number = 0,
    stdout_remainder = "",
    failures = {},
    tests = {},
    diagnostic_buffers = {},
    coverage_buffers = {},
    active_operations = {},
    operation_order = {},
    summary = nil,
    stopping = false,
  }
  sessions[root] = session
  session.stopping = false
  session.stdout_remainder = ""
  session.active_operations = {}
  session.operation_order = {}
  session.job_id = vim.fn.jobstart(
    { "gleam", "run", "-m", "kangaroo", "--", "daemon" },
    {
      cwd = root,
      stdin = "pipe",
      stdout_buffered = false,
      on_stdout = function(_, data) stdout_callback(session, data) end,
      on_stderr = function(_, data)
        local text = table.concat(data or {}, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        if text ~= "" then
          vim.schedule(function()
            vim.notify("kangaroo: " .. text, vim.log.levels.WARN)
          end)
        end
      end,
      on_exit = function()
        session.job_id = nil
        session.failures = {}
        session.active_operations = {}
        session.operation_order = {}
        clear_diagnostics(session)
        if not session.stopping then
          vim.defer_fn(function()
            if not session.stopping then start_root(root) end
          end, 200)
        end
      end,
    }
  )
  if session.job_id <= 0 then
    session.job_id = nil
    vim.notify("kangaroo: could not start daemon", vim.log.levels.ERROR)
    return session
  end
  request(session, "discover")
  request(session, "watch", { selectors = {} })
  return session
end

function M.start()
  return start_root(project_root(0))
end

local function stop_session(session)
  if session == nil then return end
  session.stopping = true
  if alive(session) then
    request(session, "shutdown")
    local job_id = session.job_id
    vim.defer_fn(function()
      if vim.fn.jobwait({ job_id }, 0)[1] == -1 then vim.fn.jobstop(job_id) end
    end, 250)
  end
  session.job_id = nil
  session.failures = {}
  session.active_operations = {}
  session.operation_order = {}
  clear_diagnostics(session)
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

function M.run(selector)
  local session = M.start()
  local selected = selector
  if selected == nil or selected == "" then selected = current_selector(session) end
  request(session, "run", { selectors = selected and { selected } or {} })
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

local function clear_coverage(session)
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

local function coverage_arguments()
  return {
    "gleam", "run", "-m", "kangaroo", "--", "coverage",
    "--coverage-reporter", "lcov",
  }
end

function M.coverage()
  local session = M.start()
  vim.system(
    coverage_arguments(),
    { cwd = session.root, text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          vim.notify("kangaroo coverage: " .. (result.stderr or result.stdout), vim.log.levels.ERROR)
          return
        end
        local path = session.root .. "/coverage/lcov.info"
        local ok, lines = pcall(vim.fn.readfile, path)
        if ok then apply_lcov(session, table.concat(lines, "\n")) end
      end)
    end
  )
end

function M.birdie()
  vim.cmd("botright split | terminal gleam run -m birdie")
end

function M.setup()
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
end

M._test = {
  apply_lcov = apply_lcov,
  coverage_arguments = coverage_arguments,
  coverage_namespace = coverage_namespace,
  failures_for = failures_for,
  latest_operation = latest_operation,
  operation_finished = operation_finished,
  operation_started = operation_started,
  relative_path = relative_path,
  select_test = select_test,
  start_root = start_root,
  take_lines = take_lines,
}

return M
