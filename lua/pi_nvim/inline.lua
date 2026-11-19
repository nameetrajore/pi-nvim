-- Decorations only: previews never change the buffer text or undo history.
local M = {}
local namespace = vim.api.nvim_create_namespace 'pi-nvim-inline'
local state = require 'pi_nvim.state'
local status = require 'pi_nvim.status'
state.inline_keys = state.inline_keys or {} -- Live upgrade from earlier versions.
local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. (vim.bo[buf].endofline and '\n' or '')
end

local bindings = { ['<C-y>'] = 'Apply', ['<C-n>'] = 'Dismiss preview' }
local function mapping(buf, key)
  return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(key, 'n', false, true) end)
end
local function restore_keys(buf)
  local saved = state.inline_keys[buf]
  if not saved then return end
  state.inline_keys[buf] = nil
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  for key, entry in pairs(saved) do
    local current = mapping(buf, key)
    if current.buffer == 1 and current.desc == entry.desc then
      vim.keymap.del('n', key, { buffer = buf })
      if entry.original then
        vim.api.nvim_buf_call(buf, function() vim.fn.mapset('n', false, entry.original) end)
      end
    end
  end
end
local function install_keys(panel)
  local buf, saved = panel.origin.buf, {}
  state.inline_keys[buf] = saved
  for key, action in pairs(bindings) do
    local old, desc = mapping(buf, key), 'Pi: inline ' .. action
    saved[key] = { original = old.buffer == 1 and old or nil, desc = desc }
    vim.keymap.set('n', key, function()
      if state.source_panel[buf] ~= panel or panel.status ~= 'proposed' or panel.dismissed
        or text(buf) ~= panel.run.before then return M.clear(buf) end
      if state.handlers and state.handlers.action then state.handlers.action(panel, action) end
    end, { buffer = buf, desc = desc, silent = true })
  end
end

function M.clear(buf)
  if not buf then return end
  restore_keys(buf)
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1) end
end

function M.show(panel)
  local buf, run = panel.origin.buf, panel.run
  if not buf or not vim.api.nvim_buf_is_loaded(buf) then return end
  M.clear(buf)
  if panel.dismissed then return end
  panel.stale = run and panel.status == 'proposed' and text(buf) ~= run.before or false
  if panel.stale or (panel.status ~= 'idle' and panel.status ~= 'proposed') then
    if panel.status == 'accepted' or panel.status == 'applied' or panel.status == 'rolled_back' then return end
    local row = math.max(0, math.min(panel.origin.row, vim.api.nvim_buf_line_count(buf) - 1))
    vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
      virt_text = { { ' Pi: ' .. status.label(panel), panel.status == 'running' and 'DiagnosticInfo' or 'DiagnosticWarn' } }, virt_text_pos = 'eol',
    })
    return
  end
  if not run or run.status ~= 'proposed' then return end
  if vim.bo[buf].fileformat ~= 'unix' or vim.bo[buf].bomb or text(buf) ~= run.before then return end
  install_keys(panel)
  local ready_row = math.max(0, math.min(panel.origin.row, vim.api.nvim_buf_line_count(buf) - 1))
  vim.api.nvim_buf_set_extmark(buf, namespace, ready_row, 0, {
    virt_text = { { run.before == run.after and ' Pi: Ready — no text changes · Ctrl-N dismiss'
      or ' Pi: Ready for review · Ctrl-Y accept · Ctrl-N dismiss', 'DiagnosticInfo' } }, virt_text_pos = 'eol',
  })
  local after = vim.split(run.after, '\n', { plain = true })
  local count, budget = vim.api.nvim_buf_line_count(buf), 120
  local hunks = vim.diff(run.before, run.after, { result_type = 'indices' })
  for _, hunk in ipairs(hunks) do
    local start, removed, added_start, added = unpack(hunk)
    local row = math.max(0, math.min(removed > 0 and start + removed - 2 or start - 1, count - 1))
    local lines = {}
    for i = start, start + removed - 1 do
      if budget <= 0 then break end
      vim.api.nvim_buf_set_extmark(buf, namespace, math.min(i - 1, count - 1), 0, { line_hl_group = 'DiffDelete' })
      budget = budget - 1
    end
    for i = added_start, added_start + added - 1 do
      if budget <= 0 then break end
      lines[#lines + 1] = { { '+ ' .. (after[i] or ''), 'DiffAdd' } }
      budget = budget - 1
    end
    if budget <= 0 then lines[#lines + 1] = { { '… preview limited to 120 lines; saved diff is complete', 'Comment' } } end
    if #lines > 0 then
      vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
        virt_lines = lines, virt_lines_above = removed == 0 and start == 0,
        virt_lines_leftcol = true,
      })
    end
    if budget <= 0 then break end
  end
end

local group = vim.api.nvim_create_augroup('PiInlinePreview', { clear = true })
vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'BufReadPost' }, {
  group = group, callback = function(event)
    M.clear(event.buf)
    local panel = state.source_panel[event.buf]
    if panel and panel.run and panel.status == 'proposed' then panel.stale = text(event.buf) ~= panel.run.before end
  end,
})
return M
