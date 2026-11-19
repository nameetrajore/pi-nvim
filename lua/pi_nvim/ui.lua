-- Floating prompt/chat; proposals themselves are rendered in the source buffer.
local M = {}
local state = require 'pi_nvim.state'
local inline = require 'pi_nvim.inline'
local status = require 'pi_nvim.status'
local panels, by_id, source_panel = state.panels, state.by_id, state.source_panel
local namespace = state.namespace

local function valid_win(win) return win and vim.api.nvim_win_is_valid(win) end
local function visible(panel) return valid_win(panel.win) and vim.api.nvim_win_get_buf(panel.win) == panel.buf end
local function source_visible(panel) return valid_win(panel.origin.win) and vim.api.nvim_win_get_buf(panel.origin.win) == panel.origin.buf end

function M.configure(handlers) state.handlers = handlers end
function M.get(id) return by_id[id] end
function M.current()
  local buf = vim.api.nvim_get_current_buf()
  for _, panel in ipairs(panels) do if panel.buf == buf then return panel end end
  return source_panel[buf]
end
function M.capture(row, col)
  return { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(),
    row = row or (vim.api.nvim_win_get_cursor(0)[1] - 1), col = col or vim.api.nvim_win_get_cursor(0)[2] }
end
function M.origin(run)
  local buf = vim.fn.bufnr(run.file)
  local win = buf >= 0 and vim.fn.bufwinid(buf) or -1
  local prefix = (run.before or ''):sub(1, run.selection and run.selection.start_byte or 0)
  local lines = vim.split(prefix, '\n', { plain = true })
  return { buf = buf, win = win ~= -1 and win or nil, row = #lines - 1, col = #lines[#lines] }
end

local function position(panel)
  local width = math.max(1, math.min(64, vim.o.columns - 4))
  local lines = vim.api.nvim_buf_is_loaded(panel.buf) and vim.api.nvim_buf_line_count(panel.buf) or 3
  local height = math.max(1, math.min(lines, 10, vim.o.lines - vim.o.cmdheight - 4))
  local origin = panel.origin
  local row, col = math.floor((vim.o.lines - height) / 2), math.floor((vim.o.columns - width) / 2)
  if source_visible(panel) then
    local mark = origin.mark and vim.api.nvim_buf_get_extmark_by_id(origin.buf, namespace, origin.mark, {}) or {}
    local mark_row = math.max(0, math.min(mark[1] or origin.row, vim.api.nvim_buf_line_count(origin.buf) - 1))
    local line = vim.api.nvim_buf_get_lines(origin.buf, mark_row, mark_row + 1, false)[1] or ''
    local mark_col = math.min(mark[2] or origin.col, #line)
    local point = vim.fn.screenpos(origin.win, mark_row + 1, mark_col + 1)
    local winpos = vim.api.nvim_win_get_position(origin.win)
    row = point.row > 0 and point.row or winpos[1] + 1
    col = point.col > 0 and point.col + 2 or winpos[2] + 2
    if col + width + 2 > vim.o.columns then col = math.max(winpos[2], col - width - 4) end
  end
  return { relative = 'editor', row = math.max(0, math.min(row, vim.o.lines - height - vim.o.cmdheight - 3)),
    col = math.max(0, math.min(col, vim.o.columns - width - 2)), width = width, height = height,
    style = 'minimal', border = 'rounded', focusable = true, zindex = 50,
    title = ' Pi · ' .. (panel.mode == 'ask' and 'Ask' or 'Edit') .. ' · ' .. status.label(panel) .. ' ', title_pos = 'left' }
end

function M.hide(panel)
  if visible(panel) then
    if vim.api.nvim_get_current_win() == panel.win then vim.cmd 'stopinsert' end
    vim.api.nvim_win_close(panel.win, true)
    panel.win = nil
  end
end

function M.actions(panel)
  local choices = {}
  if panel.mode ~= 'ask' and panel.status == 'proposed' then choices[#choices + 1] = 'Apply' end
  if panel.mode ~= 'ask' and panel.status == 'proposed' and not panel.dismissed then choices[#choices + 1] = 'Dismiss preview' end
  choices[#choices + 1] = panel.mode == 'ask' and 'Edit text' or 'Ask questions'
  vim.list_extend(choices, { 'New request', 'Requests', 'History', 'Copy Pi session command' })
  vim.ui.select(choices, { prompt = 'Pi actions' }, function(choice)
    if choice and state.handlers and state.handlers.action then state.handlers.action(panel, choice) end
  end)
end

local function prepare_buffer(panel)
  state.sequence = state.sequence + 1
  local buf = vim.api.nvim_create_buf(false, true)
  panel.buf = buf
  panel.messages = panel.messages or {}
  vim.bo[buf].buftype = 'prompt'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, 'pi://chat/' .. state.sequence)
  vim.fn.prompt_setprompt(buf, '> ')
  local lines = { '[ Actions… ]  Normal Enter: controls · Insert Enter: send', '' }
  for _, entry in ipairs(panel.messages) do
    vim.list_extend(lines, vim.split(entry, '\n', { plain = true }))
    lines[#lines + 1] = ''
  end
  vim.fn.prompt_appendbuf(buf, lines)
  vim.fn.prompt_setcallback(buf, function(text)
    if vim.trim(text) == '' then return end
    vim.schedule(function()
      if state.handlers and state.handlers.submit then state.handlers.submit(panel, text, true) end
    end)
  end)
  vim.keymap.set('n', '<CR>', function() M.actions(panel) end, { buffer = buf, desc = 'Select a Pi action' })
  vim.keymap.set('n', 'q', function() M.hide(panel) end, { buffer = buf, desc = 'Hide Pi chat' })
end

local function refresh(panel)
  if vim.api.nvim_buf_is_loaded(panel.buf) then vim.b[panel.buf].pi_run_id = panel.run and panel.run.id or nil end
  if visible(panel) then vim.api.nvim_win_set_config(panel.win, position(panel)) end
end

function M.message(panel, text, echoed)
  panel.messages = panel.messages or {}
  panel.messages[#panel.messages + 1] = text
  if vim.api.nvim_buf_is_loaded(panel.buf) and vim.bo[panel.buf].buftype == 'prompt' then
    if not echoed then vim.fn.prompt_appendbuf(panel.buf, vim.list_extend(vim.split(text, '\n', { plain = true }), { '' })) end
  end
  refresh(panel)
end

function M.present(panel, focus)
  if not panel.messages and panel.run then
    panel.messages = { 'You: ' .. panel.run.instruction, 'Pi: ' .. (panel.run.reason or '') }
  end
  if not vim.api.nvim_buf_is_loaded(panel.buf) or vim.bo[panel.buf].buftype ~= 'prompt' then
    M.hide(panel)
    prepare_buffer(panel)
  end
  local header = vim.api.nvim_buf_get_lines(panel.buf, 0, 1, false)[1] or ''
  if header:match '^%[ Actions' then
    vim.api.nvim_buf_set_lines(panel.buf, 0, 1, false, { '[ Actions… ]  Normal Enter: controls · Insert Enter: send' })
  end
  for _, other in ipairs(panels) do
    if other ~= panel and other.origin.win == panel.origin.win then M.hide(other) end
  end
  panel.detached = not source_visible(panel)
  if not visible(panel) then
    panel.win = vim.api.nvim_open_win(panel.buf, focus or false, position(panel))
    vim.wo[panel.win].wrap = true
  elseif focus then vim.api.nvim_set_current_win(panel.win) end
  if panel.origin.buf and panel.origin.buf >= 0 then
    source_panel[panel.origin.buf] = panel
    inline.show(panel)
  end
  refresh(panel)
end

function M.input(panel)
  M.present(panel, true)
  local last = vim.api.nvim_buf_line_count(panel.buf)
  local line = vim.api.nvim_buf_get_lines(panel.buf, last - 1, last, false)[1] or ''
  vim.api.nvim_win_set_cursor(panel.win, { last, #line })
  vim.cmd 'startinsert!'
end

function M.set_mode(panel, mode)
  panel.mode, panel.stale = mode, false
  local current
  if mode == 'ask' then
    if panel.run and panel.run.mode == 'ask' then current = panel.run end
  else current = panel.proposal end
  panel.status = current and current.status or 'idle'
  panel.dismissed = mode ~= 'ask' and panel.proposal and panel.dismissed_proposal == panel.proposal.id or false
  M.message(panel, mode == 'ask' and 'Ask mode: answers only, no edits.' or 'Edit mode: proposals require acceptance.')
  M.input(panel)
end

function M.new(origin, instruction)
  local panel = { origin = vim.tbl_extend('force', {}, origin), instruction = instruction or '', mode = 'edit', status = 'idle', messages = {} }
  prepare_buffer(panel)
  if origin.buf and vim.api.nvim_buf_is_loaded(origin.buf) then
    local row = math.min(origin.row, vim.api.nvim_buf_line_count(origin.buf) - 1)
    local line = vim.api.nvim_buf_get_lines(origin.buf, row, row + 1, false)[1] or ''
    panel.origin.mark = vim.api.nvim_buf_set_extmark(origin.buf, namespace, row, math.min(origin.col, #line), { right_gravity = false })
  end
  panels[#panels + 1] = panel
  M.present(panel, false)
  return panel
end

function M.begin(panel, instruction, echoed)
  panel.status, panel.instruction, panel.dismissed, panel.stale = 'running', instruction, false, false
  M.message(panel, 'You: ' .. instruction, echoed)
  if source_panel[panel.origin.buf] == panel then inline.show(panel) end
  M.hide(panel)
end

function M.update(panel, run)
  if run.mode ~= 'ask' then
    panel.proposal = (run.status == 'proposed' or run.status == 'accepted') and run or nil
  end
  if not (run.status == 'accepted' and panel.run and panel.run.id ~= run.id) then panel.run = run end
  panel.status, panel.stale = run.status, false
  panel.dismissed = panel.mode ~= 'ask' and panel.proposal and panel.dismissed_proposal == panel.proposal.id or false
  by_id[run.id] = panel
  if source_panel[panel.origin.buf] == panel then inline.show(panel) end
  M.message(panel, 'Pi [' .. status.label({ status = run.status }) .. ']: ' .. (run.answer or run.reason or '') ..
    (#(run.validation or {}) > 0 and ('\n' .. table.concat(run.validation, '\n')) or ''))
end
function M.fail(panel, message)
  panel.status = 'failed'
  M.message(panel, 'Pi: ' .. message)
  if source_panel[panel.origin.buf] == panel then inline.show(panel) end
end
function M.dismiss(panel)
  panel.dismissed = true
  local candidate = panel.proposal or panel.run
  panel.dismissed_proposal = candidate and candidate.id
  if source_panel[panel.origin.buf] == panel then inline.clear(panel.origin.buf) end
  M.message(panel, 'Preview dismissed. No changes applied; history is retained.')
end
function M.show(run, history)
  local panel = by_id[run.id]
  if not panel or not panel.run or panel.run.id ~= run.id then
    panel = M.new(M.origin(run), run.instruction)
    panel.mode = run.mode or 'edit'
    for _, entry in ipairs(history or { run }) do
      if entry.mode ~= 'ask' and (entry.status == 'proposed' or entry.status == 'accepted') then panel.proposal = entry end
      M.message(panel, 'You: ' .. entry.instruction)
      M.message(panel, 'Pi [' .. status.label({ status = entry.status }) .. ']: ' .. (entry.answer or entry.reason or ''))
    end
    panel.run, panel.status = run, run.status
    by_id[run.id] = panel
  end
  M.present(panel, true)
  return panel
end
function M.select()
  local items = {}
  for i = #panels, 1, -1 do items[#items + 1] = panels[i] end
  vim.ui.select(items, { prompt = 'Pi requests', format_item = function(panel)
    return '[' .. (panel.mode == 'ask' and 'Ask' or 'Edit') .. ' · ' .. status.label(panel) .. '] ' .. (panel.instruction ~= '' and panel.instruction or 'New request')
  end }, function(panel) if panel then M.input(panel) end end)
end

function M.refresh_all()
  for _, panel in ipairs(panels) do
    panel.mode = panel.mode or 'edit'
    if not panel.proposal and panel.run and panel.run.mode ~= 'ask' then panel.proposal = panel.run end
    if source_panel[panel.origin.buf] == panel then inline.show(panel) end
    refresh(panel)
  end
end

local group = vim.api.nvim_create_augroup('PiRequestFloats', { clear = true })
vim.api.nvim_create_autocmd({ 'WinScrolled', 'VimResized', 'BufWinEnter', 'WinClosed' }, {
  group = group, callback = function()
    vim.schedule(function()
      for _, panel in ipairs(panels) do
        if visible(panel) then
          if not panel.detached and not source_visible(panel) then M.hide(panel)
          else refresh(panel) end
        end
      end
    end)
  end,
})
return M
