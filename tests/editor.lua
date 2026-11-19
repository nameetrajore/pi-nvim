vim.g.mapleader = ' '
vim.o.lines = 40
vim.o.columns = 120
vim.keymap.set('n', '<leader>a', '<cmd>echo "harpoon"<cr>', { desc = 'Harpoon test' })
-- Simulate the previous version's mappings: remove only our action bindings.
vim.keymap.set('n', '<leader>pa', '<cmd>PiApply<cr>', { desc = 'Pi: old apply' })
vim.keymap.set('n', '<leader>ph', '<cmd>echo "user"<cr>', { desc = 'User history' })
vim.opt.runtimepath:prepend(vim.fn.getcwd())
require('pi_nvim').setup { cli = vim.fn.getcwd() .. '/pi_nvim.py' }
local ui = require 'pi_nvim.ui'
local file, fixture_id = vim.env.PI_NVIM_TEST_FILE, vim.env.PI_NVIM_TEST_RUN
local inline_ns = vim.api.nvim_create_namespace 'pi-nvim-inline'
local errors = {}
vim.notify = function(message) errors[#errors + 1] = message end
vim.fn.confirm = function() return 1 end
for _, name in ipairs { 'PiRun', 'PiConfig', 'PiHistory', 'PiApply', 'PiShow', 'PiReload', 'PiSource', 'PiRequests', 'PiActions', 'PiCopyCommand' } do
  assert(vim.fn.exists(':' .. name) == 2, name .. ' missing')
end
assert(vim.fn.exists ':PiRevise' == 0 and vim.fn.exists ':PiRollback' == 0)
assert(vim.fn.maparg(' a', 'n', false, true).desc == 'Harpoon test')
assert(vim.fn.maparg(' ph', 'n', false, true).desc == 'User history')
for _, key in ipairs { 'a', 'd', 'u', 'c', 'r', 'e', 'l' } do assert(vim.fn.maparg(' p' .. key, 'n') == '') end
assert(vim.fn.maparg(' pi', 'n') ~= '')
assert(vim.fn.maparg('<C-y>', 'n') == '' and vim.fn.maparg('<C-e>', 'n') == '')

local function feed(keys)
  -- Cancel deferred :startinsert before synchronously driving Normal/Insert keys.
  vim.cmd 'stopinsert'
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end
local function send(text)
  assert(vim.bo.buftype == 'prompt', 'Instructions must be typed into the floating chat')
  feed('<Esc>A<C-u>' .. text .. '<CR><Esc>')
end
local function wait_panel(panel, previous)
  assert(vim.wait(7000, function()
    return panel.status ~= 'running' and panel.run ~= nil and panel.run.id ~= previous
  end), 'Request did not finish: ' .. vim.inspect(panel))
  return vim.deepcopy(panel.run)
end
local function choose(panel, action)
  ui.present(panel, true)
  vim.cmd 'stopinsert'
  vim.ui.select = function(items, _, callback)
    assert(not vim.tbl_contains(items, 'Revise') and not vim.tbl_contains(items, 'Rollback'), 'Redundant controls returned')
    assert(vim.tbl_contains(items, action), 'Action missing: ' .. action)
    callback(action)
  end
  vim.api.nvim_win_set_cursor(panel.win, { 1, 0 })
  feed('<CR>')
end
local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, inline_ns, 0, -1, { details = true })
end

vim.cmd.edit(vim.fn.fnameescape(file))
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local original_n_calls = 0
vim.keymap.set('n', '<C-y>', function() end, { desc = 'Existing global Ctrl-Y' })
vim.keymap.set('n', '<C-n>', function() original_n_calls = original_n_calls + 1 end, { buffer = source, desc = 'Existing local Ctrl-N' })
vim.keymap.set('n', '<C-e>', function() end, { desc = 'Harpoon Ctrl-E' })
-- A saved proposal loaded through history becomes chat plus inline decorations.
vim.ui.select = function(items, _, callback)
  for _, item in ipairs(items) do if item.id == fixture_id then callback(item); return end end
  error('History fixture missing')
end
vim.cmd 'PiHistory'
assert(vim.wait(5000, function() return vim.bo.buftype == 'prompt' and ui.current().run ~= nil end))
local fixture = ui.current()
assert(vim.api.nvim_win_get_config(0).relative ~= '')
assert(#marks(source) > 0)
ui.hide(fixture)
-- A proposal still cannot overwrite newer source edits.
vim.api.nvim_buf_set_lines(source, 0, -1, false, { '# Unsaved' })
vim.cmd('PiApply ' .. fixture_id)
assert(vim.wait(3000, function() return table.concat(errors, '\n'):find('changed', 1, true) ~= nil end))
assert(vim.fn.readfile(file)[1] == '# Before')
vim.cmd 'edit!'

-- Type a real prompt via native prompt-buffer Enter; source and undo tree stay untouched.
vim.fn.writefile({ 'prefix café suffix', 'Second line', 'Last' }, file)
vim.cmd 'edit!'
vim.cmd 'let &g:undolevels = &g:undolevels'
vim.api.nvim_buf_set_lines(source, 2, 3, false, { 'Last unsaved' })
vim.cmd 'let &g:undolevels = &g:undolevels'
assert(vim.bo[source].modified)
local initial_undo = vim.fn.undotree().seq_cur
vim.api.nvim_win_set_cursor(source_win, { 1, 7 })
vim.cmd 'normal! v'
vim.api.nvim_win_set_cursor(source_win, { 1, 10 })
vim.fn.maparg(' pi', 'x', false, true).callback()
local chat = ui.current()
assert(vim.bo.buftype == 'prompt' and chat.status == 'idle')
assert(vim.api.nvim_win_get_config(0).height <= 4, 'Draft should be a compact input bar')
vim.cmd 'redraw'
local source_point = vim.fn.screenpos(source_win, 1, 8)
assert(source_point.row > 0)
assert(vim.api.nvim_win_get_config(chat.win).row == source_point.row, 'Input is not anchored near the requested text')
assert(vim.fn.maparg('<C-y>', 'i') == '' and vim.fn.maparg('<C-e>', 'i') == '')
send('Improve selected text')
local first = wait_panel(chat)
assert(first.status == 'proposed', first.reason)
assert(first.selection.text == 'café')
assert(first.after == 'prefix EDITED suffix\nSecond line\nLast unsaved\n')
assert(first.source == 'buffer' and first.before:find('Last unsaved', 1, true))
assert(vim.api.nvim_get_current_win() == source_win, 'Submission/completion stole source focus')
assert(vim.fn.readfile(file)[1] == 'prefix café suffix')
assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == 'prefix café suffix')
assert(vim.fn.undotree().seq_cur == initial_undo, 'Preview changed undo history')
local decorated = marks(source)
assert(vim.iter(decorated):any(function(mark) return mark[4].virt_lines ~= nil end), 'Expected inline virtual diff lines')

-- Revise inside the same chat, keeping its transcript and buffer identity.
local chat_buf, count = chat.buf, #vim.api.nvim_list_bufs()
require('pi_nvim').open()
send('Make it shorter')
local revised = wait_panel(chat, first.id)
assert(revised.parent == first.id and revised.after == 'prefix REVISED suffix\nSecond line\nLast unsaved\n')
assert(chat.buf == chat_buf and #vim.api.nvim_list_bufs() == count)
local transcript = table.concat(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false), '\n')
assert(transcript:find('Improve selected text', 1, true) and transcript:find('Make it shorter', 1, true))
assert(transcript:find('Ready — awaiting your review', 1, true))

-- Inline Ctrl-Y accepts; source remains a single native undo step.
assert(vim.fn.maparg('<C-y>', 'n', false, true).desc == 'Pi: inline Apply')
assert(vim.fn.maparg('<C-e>', 'n', false, true).desc == 'Harpoon Ctrl-E')
feed('<C-y>')
assert(vim.wait(5000, function() return chat.status == 'accepted' end))
assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == 'prefix REVISED suffix')
assert(vim.bo[source].modified and vim.fn.readfile(file)[1] == 'prefix café suffix')
assert(vim.fn.readfile(file)[3] == 'Last', 'Acceptance saved prior unsaved edits')
assert(#vim.api.nvim_list_bufs() == count and chat.buf == chat_buf)
assert(#marks(source) == 0)
assert(vim.fn.maparg('<C-y>', 'n', false, true).desc == 'Existing global Ctrl-Y')
assert(vim.fn.maparg('<C-n>', 'n', false, true).desc == 'Existing local Ctrl-N')
feed('u')
assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == 'prefix café suffix')
assert(vim.api.nvim_buf_get_lines(source, 2, 3, false)[1] == 'Last unsaved')
assert(vim.fn.undotree().seq_cur == initial_undo and vim.bo[source].modified)
feed('<C-r>')
assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == 'prefix REVISED suffix')
feed('u')
feed('u')
assert(vim.api.nvim_buf_get_lines(source, 2, 3, false)[1] == 'Last', 'Prior user edit was merged into acceptance')
feed('<C-r>')
assert(vim.api.nvim_buf_get_lines(source, 2, 3, false)[1] == 'Last unsaved')
assert(vim.wait(5000, function()
  local record = vim.json.decode(table.concat(vim.fn.readfile(vim.env.PI_NVIM_STATE .. '/' .. revised.id .. '.json'), '\n'))
  return record.status == 'accepted'
end))
-- History records acceptance, not the current undo state; chat continues from today's buffer.
require('pi_nvim').open()
send('Continue from the current text')
local continued = wait_panel(chat, revised.id)
assert(continued.parent == revised.id and continued.before == 'prefix café suffix\nSecond line\nLast unsaved\n')
assert(not continued.selection, 'A stale selection was reused after acceptance')
choose(chat, 'Dismiss preview')
ui.hide(chat)
assert(vim.fn.readfile(file)[3] == 'Last')
vim.cmd 'write'
assert(vim.fn.readfile(file)[3] == 'Last unsaved' and not vim.bo[source].modified)

-- Reversed/exclusive and linewise selection use exact Neovim region semantics.
vim.o.selection = 'exclusive'
vim.api.nvim_win_set_cursor(source_win, { 1, 10 })
vim.cmd 'normal! v'
vim.api.nvim_win_set_cursor(source_win, { 1, 7 })
local expected = table.concat(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = 'v' }), '\n')
require('pi_nvim').select_request()
local reversed = ui.current()
send('Reverse selection test')
assert(wait_panel(reversed).selection.text == expected)
vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
vim.cmd 'normal! V'
require('pi_nvim').select_request()
local linewise = ui.current()
send('Linewise selection test')
assert(wait_panel(linewise).selection.text == 'Second line\n')
vim.cmd '2,2PiRun Range test'
local ranged = ui.current()
assert(wait_panel(ranged).selection.text == 'Second line\n')

-- Inline Ctrl-N dismisses and restores an existing Lua buffer-local mapping.
assert(vim.fn.maparg('<C-n>', 'n', false, true).desc == 'Pi: inline Dismiss preview')
feed('<C-n>')
assert(original_n_calls == 0)
assert(vim.fn.maparg('<C-n>', 'n', false, true).desc == 'Existing local Ctrl-N')
feed('<C-n>')
assert(original_n_calls == 1)
assert(vim.fn.maparg('<C-e>', 'n', false, true).desc == 'Harpoon Ctrl-E')
assert(#marks(source) == 0 and ranged.dismissed)
assert(vim.fn.filereadable(vim.env.PI_NVIM_STATE .. '/' .. ranged.run.id .. '.json') == 1)
ui.hide(ranged)

-- Independent chats run concurrently and complete out of order without replacing each other.
vim.cmd 'PiRun Slow request'
local slow = ui.current()
vim.cmd 'PiRun Fast request'
local fast = ui.current()
assert(slow ~= fast and slow.status == 'running' and fast.status == 'running')
wait_panel(fast)
assert(slow.status == 'running', 'Jobs did not overlap')
local active_before = marks(source)
vim.cmd 'PiReload'
wait_panel(slow)
assert(ui.current() == fast and vim.api.nvim_get_current_win() == source_win)
assert(vim.deep_equal(marks(source), active_before), 'Late completion replaced the selected inline preview')
choose(fast, 'Apply')
assert(vim.wait(5000, function() return fast.status == 'accepted' end))
ui.hide(fast)
errors = {}
vim.cmd('PiApply ' .. slow.run.id)
assert(vim.wait(3000, function() return table.concat(errors, '\n'):find('changed', 1, true) ~= nil end))
assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == 'EDITED')
assert(vim.fn.readfile(file)[1] == 'prefix café suffix', 'Concurrent acceptance wrote to disk')

-- A completion appends chat output without destroying a partially typed revision.
vim.cmd 'PiRun Slow draft preservation'
local draft = ui.current()
ui.input(draft)
feed('<Esc>APending feedback<Esc>')
assert(vim.fn.prompt_getinput(draft.buf) == 'Pending feedback', 'Initial draft: ' .. vim.inspect(vim.fn.prompt_getinput(draft.buf)) .. ' lines: ' .. vim.inspect(vim.api.nvim_buf_get_lines(draft.buf, 0, -1, false)))
wait_panel(draft)
assert(vim.fn.prompt_getinput(draft.buf) == 'Pending feedback', 'Changed draft: ' .. vim.inspect(vim.fn.prompt_getinput(draft.buf)))
assert(vim.api.nvim_get_current_win() == draft.win, 'Completion moved chat focus')
ui.hide(draft)

-- Copy a safe command/context file; never start an interactive process or terminal.
local wins = #vim.api.nvim_list_wins()
vim.cmd 'PiCopyCommand'
assert(vim.wait(5000, function() return vim.fn.getreg('"'):find('&& pi --model openai-codex/gpt-6.1-terra -- ', 1, true) ~= nil end))
assert(#vim.api.nvim_list_wins() <= wins + 1, 'Copying a command launched another window')
assert(vim.fn.getreg('"'):find('cd -- ', 1, true) == 1)
assert(table.concat(vim.api.nvim_buf_get_lines(draft.buf, 0, -1, false), '\n'):find('separate terminal', 1, true))
ui.hide(draft)

-- Source edits remove decorations immediately, while approval remains stale-safe.
vim.fn.writefile({ '# Fresh source' }, file)
vim.cmd 'edit!'
vim.cmd 'PiRun Source edits test'
local stale = ui.current()
wait_panel(stale)
assert(#marks(source) > 0)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'Changed buffer' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
assert(#marks(source) == 0)
vim.cmd 'edit!'

-- A newly named, unsaved buffer can request and accept without creating a disk file.
local new_file = file .. '.new.md'
vim.cmd.edit(vim.fn.fnameescape(new_file))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '# Unsaved new document' })
local new_buf = vim.api.nvim_get_current_buf()
vim.cmd 'PiRun Edit new buffer'
local new_chat = ui.current()
local new_run = wait_panel(new_chat)
assert(new_run.before == '# Unsaved new document\n')
choose(new_chat, 'Apply')
assert(vim.wait(5000, function() return new_chat.status == 'accepted' end))
assert(vim.api.nvim_buf_get_lines(new_buf, 0, 1, false)[1] == 'EDITED')
assert(vim.fn.filereadable(new_file) == 0, 'Native acceptance created a file')
feed('u')
assert(vim.api.nvim_buf_get_lines(new_buf, 0, 1, false)[1] == '# Unsaved new document')
assert(vim.fn.filereadable(new_file) == 0)
vim.cmd.edit { args = { vim.fn.fnameescape(file) }, bang = true }

-- Clarification is explicitly different from Working and Ready; it has no accept key.
vim.cmd 'PiRun Clarify request'
local clarification = ui.current()
assert(require('pi_nvim.status').label(clarification) == 'Working…')
wait_panel(clarification)
assert(clarification.status == 'needs_clarification')
assert(require('pi_nvim.status').label(clarification) == 'Needs your input — reply in chat')
assert(vim.fn.maparg('<C-y>', 'n', false, true).desc ~= 'Pi: inline Apply')

-- Failure isolation and UI-code reload preserve chat identity.
vim.cmd 'PiRun Fail request'
local failed = ui.current()
vim.cmd 'PiRun Fast after failure'
local succeeded = ui.current()
wait_panel(failed)
wait_panel(succeeded)
assert(failed.status == 'failed' and succeeded.status == 'proposed')
local final_buffers = #vim.api.nvim_list_bufs()
vim.cmd 'PiReload'
local reloaded = require 'pi_nvim.ui'
assert(reloaded ~= ui and reloaded.current() == succeeded)
assert(reloaded.get(succeeded.run.id) == succeeded)
vim.cmd 'PiShow'
assert(#vim.api.nvim_list_bufs() == final_buffers)
assert(vim.bo.buftype == 'prompt' and not vim.bo.buflisted)
vim.cmd 'qa!'
