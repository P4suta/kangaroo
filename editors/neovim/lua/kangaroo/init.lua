--- kangaroo.nvim — continuous test results in Neovim.
---
--- Runs `kangaroo_cli watch --json` in the background, parses the
--- newline-delimited protocol stream, and surfaces failures as
--- diagnostics and a quickfix list. Use:
---
---     :KangarooStart        start watching the project
---     :KangarooStop         stop watching
---     :KangarooQuickfix     jump to the failures
---     :KangarooStatus       show the last run's summary
---
--- The plugin follows the terminal output of the watch process: the
--- failure markers in the quickfix list reflect the most recent run.
local M = {}

local job_id = nil
local line_buffer = {}
local diagnostics_buffer = {}
local summary = nil
local namespace = vim.api.nvim_create_namespace("kangaroo")

--- Splits an NDJSON chunk into complete lines.
local function take_lines(data)
  for _, line in ipairs(data) do
    line_buffer[#line_buffer + 1] = line
  end
  local complete = {}
  local joined = table.concat(line_buffer, "\n")
  line_buffer = {}
  for line in joined:gmatch("[^\n]*\n?") do
    if line ~= "" then
      if line:sub(-1) == "\n" then
        complete[#complete + 1] = line:sub(1, -2)
      else
        line_buffer = { line }
      end
    end
  end
  return complete
end

--- Converts a protocol failure into a vim.diagnostic.severity.
local function severity()
  return vim.diagnostic.severity.ERROR
end

--- Turns protocol failures into diagnostics entries for one file.
local function failures_for(event)
  local outcome = event.outcome
  if outcome == nil or outcome.kind ~= "failed" then
    return {}
  end
  local entries = {}
  for _, failure in ipairs(outcome.failures or {}) do
    local location = failure.location
    if location ~= nil and location.file ~= nil then
      local message = failure.message
        or ("expected: " .. (failure.expected or "?") .. ", actual: " .. (failure.actual or "?"))
      entries[#entries + 1] = {
        file = location.file,
        lnum = location.line or 1,
        col = (location.column or 1) + 1,
        message = message,
        severity = severity(),
      }
    end
  end
  return entries
end

--- Rebuilds the diagnostics for the current run.
local function rebuild_diagnostics()
  local by_file = {}
  for _, entry in ipairs(diagnostics_buffer) do
    by_file[entry.file] = by_file[entry.file] or {}
    by_file[entry.file][#by_file[entry.file] + 1] = {
      lnum = entry.lnum,
      col = entry.col,
      message = entry.message,
      severity = entry.severity,
    }
  end
  -- Clear previous diagnostics for the watched files.
  for file, _ in pairs(by_file) do
    vim.diagnostic.reset(namespace, vim.fn.bufnr(file, true))
  end
  for file, entries in pairs(by_file) do
    local bufnr = vim.fn.bufnr(file, true)
    vim.diagnostic.set(namespace, bufnr, entries)
  end
end

--- Handles one protocol event.
local function handle(event)
  if event.type == "case_finished" then
    for _, entry in ipairs(failures_for(event)) do
      diagnostics_buffer[#diagnostics_buffer + 1] = entry
    end
  elseif event.type == "run_started" then
    diagnostics_buffer = {}
  elseif event.type == "run_finished" then
    summary = event.summary
    rebuild_diagnostics()
  end
end

local function on_stdout(_, data)
  for _, line in ipairs(take_lines(data)) do
    local ok, event = pcall(vim.json.decode, line)
    if ok and type(event) == "table" then
      handle(event)
    end
  end
end

--- Starts the watch process in the current directory.
function M.start()
  if job_id ~= nil and vim.fn.jobwait({ job_id }, 0)[1] == -1 then
    return
  end
  line_buffer = {}
  diagnostics_buffer = {}
  summary = nil
  local cwd = vim.fn.getcwd()
  job_id = vim.fn.jobstart(
    { "gleam", "run", "-m", "kangaroo_cli", "--", "watch", "--json" },
    {
      cwd = cwd,
      stdout_buffered = false,
      on_stdout = on_stdout,
      on_stderr = function() end,
    }
  )
  if job_id <= 0 then
    vim.notify("kangaroo: could not start the watch process", vim.log.levels.ERROR)
    job_id = nil
  end
end

--- Stops the watch process.
function M.stop()
  if job_id ~= nil then
    vim.fn.jobstop(job_id)
    job_id = nil
  end
  vim.diagnostic.reset(namespace)
end

--- Fills the quickfix list with the failures of the current run.
function M.quickfix()
  local items = {}
  for _, entry in ipairs(diagnostics_buffer) do
    items[#items + 1] = {
      filename = entry.file,
      lnum = entry.lnum,
      col = entry.col,
      text = entry.message,
    }
  end
  if #items == 0 then
    vim.notify("kangaroo: no failures", vim.log.levels.INFO)
    return
  end
  vim.fn.setqflist({}, "r", { items = items, title = "kangaroo" })
  vim.cmd("copen")
end

--- Shows the last run's summary.
function M.status()
  if summary == nil then
    vim.notify("kangaroo: no run yet", vim.log.levels.INFO)
    return
  end
  vim.notify(string.format(
    "kangaroo: %d passed, %d failed, %d skipped (in %dms)",
    summary.passed, summary.failed, summary.skipped, summary.duration_ms
  ), summary.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

--- Toggles the watcher.
function M.toggle()
  if job_id ~= nil and vim.fn.jobwait({ job_id }, 0)[1] == -1 then
    M.stop()
  else
    M.start()
  end
end

vim.api.nvim_create_user_command("KangarooStart", M.start, {})
vim.api.nvim_create_user_command("KangarooStop", M.stop, {})
vim.api.nvim_create_user_command("KangarooQuickfix", M.quickfix, {})
vim.api.nvim_create_user_command("KangarooStatus", M.status, {})
vim.api.nvim_create_user_command("Kangaroo", M.toggle, {})

return M
