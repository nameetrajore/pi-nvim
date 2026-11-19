local M = {}
local options = { cli = vim.fn.stdpath 'config' .. '/scripts/pi_nvim.py', model = 'openai-codex/gpt-6.1-terra' }
local last_run
local jobs = {}
local ui = require 'pi_nvim.ui'
local buffer = require 'pi_nvim.buffer'

local function decode(text)
  return vim.json.decode(text, { luanil = { object = true, array = true } })
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'Pi Neovim' })
end

local function call(args, callback, snapshot)
  local cmd = { 'python3', options.cli }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true, stdin = snapshot }, vim.schedule_wrap(function(result)
    local ok, data = pcall(decode, result.stdout or '')
    if not ok then
      notify(result.stderr ~= '' and result.stderr or 'Invalid CLI response', vim.log.levels.ERROR)
      return
    end
    if data.error then
      notify(data.error, vim.log.levels.ERROR)
      return
    end
    callback(data)
  end))
end

local function show(run)
  last_run = run.id
  if ui.get(run.id) then return ui.show(run) end
  call({ 'thread', run.id }, function(history) ui.show(run, history) end)
end

local function selected_id(explicit)
  if explicit and explicit ~= '' then return explicit end
  local panel = ui.current()
  if panel then
    local candidate = panel.proposal or panel.run
    return panel.status ~= 'running' and candidate and candidate.id or nil
  end
  return vim.b.pi_run_id or last_run
end

local function launch(args, panel, instruction, echoed, snapshot)
  if options.model then vim.list_extend(args, { '--model', options.model }) end
  jobs[panel] = true
  ui.begin(panel, instruction, echoed)
  local cmd = { 'python3', options.cli }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, { text = true, stdin = snapshot }, vim.schedule_wrap(function(result)
    jobs[panel] = nil
    local decoded, data = pcall(decode, result.stdout or '')
    if not decoded or type(data) ~= 'table' or data.error then
      local message = type(data) == 'table' and data.error or (result.stderr ~= '' and result.stderr or 'Invalid response')
      ui.fail(panel, message)
      return notify(message, vim.log.levels.ERROR)
    end
    last_run = data.id
    ui.update(panel, data)
  end))
  if not ok then
    jobs[panel] = nil
    ui.fail(panel, tostring(err))
    notify(tostring(err), vim.log.levels.ERROR)
  end
end

local function submit(panel, instruction, echoed)
  if not instruction or vim.trim(instruction) == '' then return end
  if jobs[panel] then return ui.message(panel, 'Pi is still working. Send feedback once it finishes, or start a new request.') end
  local data, run = panel.request_data, panel.run
  local buf = data and data.buf or panel.origin.buf
  if not buf or not vim.api.nvim_buf_is_loaded(buf) or not buffer.supported(buf) then
    return ui.message(panel, 'Open the UTF-8/Unix source buffer before sending.')
  end
  local snapshot = buffer.text(buf)
  local file = run and run.file or (data and data.file)
  local name = vim.api.nvim_buf_get_name(buf)
  if not file or (vim.fs.normalize(name) ~= file and vim.uv.fs_realpath(name) ~= file) then
    return ui.message(panel, 'Source buffer was renamed. Start a new request.')
  end
  local candidate = panel.proposal or (run and run.mode ~= 'ask' and run or nil)
  if candidate and snapshot == candidate.before and (candidate.status == 'proposed' or candidate.status == 'rejected'
    or candidate.status == 'needs_clarification' or candidate.status == 'failed') then
    local args = { 'revise', candidate.id, instruction, '--mode', 'auto', '--source-stdin' }
    if run then vim.list_extend(args, { '--parent', run.id }) end
    return launch(args, panel, instruction, echoed, snapshot)
  end
  local root, kind = run and run.workspace or data.root, run and run.kind or data.kind
  local scope = data and snapshot == data.snapshot and data.scope or nil
  if candidate and (candidate.status == 'accepted' or candidate.status == 'applied' or candidate.status == 'rolled_back') then scope = nil end
  local args = { 'run', file, instruction, '--workspace', root, '--kind', kind, '--mode', 'auto', '--source-stdin' }
  if run then vim.list_extend(args, { '--parent', run.id }) end
  if scope then
    vim.list_extend(args, { '--start-byte', tostring(scope.start), '--end-byte', tostring(scope.finish), '--expected-sha256', vim.fn.sha256(snapshot) })
  end
  launch(args, panel, instruction, echoed, snapshot)
end

local function source_supported(buf)
  if not buffer.supported(buf) then
    notify 'Buffer edits require UTF-8, Unix line endings, and no BOM'
    return false
  end
  return true
end

local function request(opts, kind, scope)
  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  if file == '' or vim.bo[buf].buftype ~= '' then return notify 'Open a named source buffer first' end
  if not source_supported(buf) then return end
  if opts.range and opts.range > 0 then
    scope = { start = vim.fn.line2byte(opts.line1) - 1,
      finish = opts.line2 == vim.api.nvim_buf_line_count(buf) and #buffer.text(buf) or vim.fn.line2byte(opts.line2 + 1) - 1 }
  end
  local origin = ui.capture(opts.range and opts.range > 0 and opts.line1 - 1 or (scope and scope.row), scope and scope.col)
  if scope then
    scope.sha256 = vim.fn.sha256(buffer.text(buf))
  end
  local root = kind == 'config' and vim.fn.stdpath 'config'
    or (vim.fs.root(file, { '.git', '.obsidian' }) or vim.fs.dirname(file))
  local panel = ui.new(origin)
  panel.request_data = { buf = buf, snapshot = buffer.text(buf), file = file, root = root, kind = kind, scope = scope }
  if opts.args ~= '' then submit(panel, opts.args) else ui.input(panel) end
end

function M.select_request()
  local mode = vim.fn.mode()
  if mode ~= 'v' and mode ~= 'V' then return notify 'Use characterwise or linewise Visual mode (not blockwise)' end
  if not source_supported(0) then return end
  local region = vim.fn.getregionpos(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = mode, eol = true })
  if #region == 0 then return end
  for _, pair in ipairs(region) do
    if pair[1][4] ~= 0 or pair[2][4] ~= 0 then return notify 'Virtual-column selections are not supported' end
  end
  local first, last = region[1][1], region[#region][2]
  local text = table.concat(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = mode }), '\n')
  if mode == 'V' and (last[2] < vim.api.nvim_buf_line_count(0) or vim.bo.endofline) then text = text .. '\n' end
  local start = vim.fn.line2byte(first[2]) - 1 + math.max(0, first[3] - 1)
  vim.cmd('normal! ' .. string.char(27))
  request({ args = '' }, 'markdown', { start = start, finish = start + #text, row = first[2] - 1, col = math.max(0, first[3] - 1) })
end

local function apply(id)
  id = selected_id(id)
  if not id then return notify 'Select a completed proposal first' end
  call({ 'show', id }, function(run)
    local panel = ui.get(id)
    local buf = panel and panel.origin.buf or vim.fn.bufnr(run.file)
    local ok, error = pcall(buffer.apply, run, buf)
    if not ok then return notify(tostring(error), vim.log.levels.ERROR) end
    local accepted = vim.tbl_extend('force', run, { status = 'accepted', application = 'buffer' })
    if panel then
      ui.update(panel, accepted)
      ui.message(panel, 'Accepted into the buffer, not saved. Use u / Ctrl-R and :write normally.')
      ui.hide(panel)
    end
    -- History records an acceptance event, not a save or the buffer's current undo position.
    local started, err = pcall(vim.system, { 'python3', options.cli, 'accept-buffer', id }, { text = true },
      vim.schedule_wrap(function(result)
        local decoded, data = pcall(decode, result.stdout or '')
        if not decoded or type(data) ~= 'table' or data.error or result.code ~= 0 then
          notify('Buffer edit retained, but history could not record acceptance. Save or undo normally.', vim.log.levels.WARN)
        end
      end))
    if not started then notify('Buffer edit retained; history update failed: ' .. tostring(err), vim.log.levels.WARN) end
  end)
end

function M.open()
  local panel = ui.current()
  if panel then ui.input(panel) else request({ args = '' }, 'markdown') end
end

local function copy_command(panel)
  if not panel or not panel.run or panel.status == 'running' then return notify 'Wait for a completed request first' end
  local args, snapshot = { 'handoff', panel.run.id }, nil
  local buf = panel.origin.buf
  if buf and vim.api.nvim_buf_is_loaded(buf) and buffer.supported(buf) then
    args[#args + 1], snapshot = '--source-stdin', buffer.text(buf)
  end
  call(args, function(data)
    vim.fn.setreg('"', data.command)
    if vim.fn.has('clipboard') == 1 then pcall(vim.fn.setreg, '+', data.command) end
    ui.message(panel, 'Command copied to the unnamed register (and clipboard if available). Paste into a separate terminal:\n' .. data.command)
    ui.present(panel, true)
  end, snapshot)
end

function M.setup(opts)
  options = vim.tbl_extend('force', options, opts or {})
  ui.configure({ submit = submit, action = function(panel, choice)
    if choice == 'Dismiss preview' then return ui.dismiss(panel) end
    if choice == 'Requests' then return ui.select() end
    if choice == 'History' then return vim.cmd 'PiHistory' end
    if choice == 'Copy Pi session command' then return copy_command(panel) end
    if choice == 'New request' then
      ui.hide(panel)
      if panel.origin.win and vim.api.nvim_win_is_valid(panel.origin.win)
        and vim.api.nvim_win_get_buf(panel.origin.win) == panel.origin.buf then
        vim.api.nvim_set_current_win(panel.origin.win)
        local kind = panel.run and panel.run.kind or (panel.request_data and panel.request_data.kind) or 'markdown'
        return request({ args = '' }, kind)
      end
      return notify 'Open the source file, then use :PiRun'
    end
    if not panel.run or panel.status == 'running' then return ui.message(panel, 'Wait for this request to finish first.') end
    if choice == 'Apply' then
      local candidate = panel.proposal or panel.run
      if candidate then apply(candidate.id) end
    end
  end })
  local function command(name, fn, spec)
    vim.api.nvim_create_user_command(name, fn, vim.tbl_extend('force', { force = true }, spec or {}))
  end
  command('PiRun', function(o) request(o, 'markdown') end, { nargs = '*', range = true, desc = 'Propose a Markdown edit' })
  -- Chat is the revision interface; native undo replaces editor-side rollback.
  for _, name in ipairs { 'PiRevise', 'PiRollback' } do pcall(vim.api.nvim_del_user_command, name) end
  command('PiConfig', function(o) request(o, 'config') end, { nargs = '*', desc = 'Propose a Lua config edit' })
  command('PiHistory', function()
    call({ 'history' }, function(runs)
      vim.ui.select(runs, { prompt = 'Pi runs', format_item = function(r)
        return r.created:sub(1, 19) .. ' [' .. r.status .. '] ' .. r.instruction .. ' — ' .. vim.fn.fnamemodify(r.file, ':t')
      end }, function(run)
        if run then call({ 'show', run.id }, show) end
      end)
    end)
  end, { desc = 'Browse persistent Pi run history' })
  command('PiRequests', ui.select, { desc = 'Switch between running and completed requests' })
  command('PiActions', function()
    local panel = ui.current()
    if panel then ui.actions(panel) else notify 'Open a Pi chat first' end
  end)
  command('PiCopyCommand', function() copy_command(ui.current()) end)
  command('PiShow', function(o)
    local panel = o.args == '' and ui.current() or nil
    if panel then return ui.present(panel, true) end
    local id = selected_id(o.args)
    if id then call({ 'show', id }, show) else notify 'No run selected' end
  end, { nargs = '?' })
  command('PiApply', function(o) apply(o.args) end, { nargs = '?' })
  command('PiReload', function()
    if next(jobs) then return notify 'Wait for running requests before reloading' end
    package.loaded['pi_nvim'] = nil
    package.loaded['pi_nvim.ui'] = nil
    package.loaded['pi_nvim.inline'] = nil
    package.loaded['pi_nvim.buffer'] = nil
    package.loaded['pi_nvim.status'] = nil
    require('pi_nvim').setup(options)
    notify 'Pi integration reloaded'
  end, { desc = 'Reload only the Pi integration' })
  command('PiSource', function()
    local file = vim.api.nvim_buf_get_name(0)
    local config = vim.fn.stdpath 'config' .. '/'
    if vim.bo.modified or file:sub(1, #config) ~= config or not file:match '%.lua$' then
      return notify 'Open a saved Lua file inside your Neovim config first'
    end
    local chunk, err = loadfile(file)
    if not chunk then return notify(err, vim.log.levels.ERROR) end
    if vim.fn.confirm('Execute this Lua config now? Side effects cannot be rolled back.\n' .. file, '&Yes\n&No', 2) ~= 1 then return end
    local ok, failure = xpcall(chunk, debug.traceback)
    if not ok then notify(failure, vim.log.levels.ERROR)
    else notify 'Config executed; non-idempotent plugins may still require restart' end
  end, { desc = 'Explicitly execute the current saved Lua config' })
  -- Retire our earlier action shortcuts without touching user-defined mappings.
  for _, key in ipairs { 'h', 'd', 'a', 'u', 'c', 'r', 'e', 'l' } do
    local lhs = '<leader>p' .. key
    local old = vim.fn.maparg(lhs, 'n', false, true)
    if (old.desc or ''):match '^Pi: ' then vim.keymap.del('n', lhs) end
  end
  if options.mappings ~= false then
    local function map(mode, rhs, desc)
      local old = vim.fn.maparg('<leader>pi', mode, false, true)
      if next(old) ~= nil and not (old.desc or ''):match '^Pi: ' then return end
      vim.keymap.set(mode, '<leader>pi', rhs, { desc = 'Pi: ' .. desc })
    end
    map('n', M.open, 'open chat')
    map('x', M.select_request, 'chat about selected text')
  end
  ui.refresh_all()
end

return M
