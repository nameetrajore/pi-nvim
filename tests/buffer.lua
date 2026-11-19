vim.opt.runtimepath:prepend(vim.fn.getcwd())
local buffer = require 'pi_nvim.buffer'
local function fixture(before, after)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  local name = vim.fn.tempname() .. '.md'
  vim.api.nvim_buf_set_name(buf, name)
  local lines = vim.split(before, '\n', { plain = true })
  if before:sub(-1) == '\n' then table.remove(lines) end
  vim.bo[buf].endofline = before:sub(-1) == '\n'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.cmd 'let &g:undolevels = &g:undolevels'
  return buf, { status = 'proposed', file = name, before = before, after = after }
end
for _, texts in ipairs {
  { 'keep\nold A\nmiddle\nold B\nend\n', 'keep\nnew A\nmiddle\nnew B\nend\n' },
  { 'head\n', 'head\ntail\n' }, { 'head\ntail\n', 'head\n' },
  { 'only\n', '\n' }, { 'no final newline', 'still no final newline' },
} do
  local buf, run = fixture(unpack(texts))
  local global_ul = vim.go.undolevels
  vim.bo[buf].undolevels = 2000
  local eol = vim.bo[buf].endofline
  local seq = vim.fn.undotree().seq_cur
  buffer.apply(run, buf)
  assert(buffer.text(buf) == run.after)
  assert(vim.go.undolevels == global_ul and vim.bo[buf].undolevels == 2000)
  vim.cmd 'normal! u'
  assert(buffer.text(buf) == run.before and vim.fn.undotree().seq_cur == seq, 'Acceptance was not a separate undo step')
  vim.cmd('normal! ' .. string.char(18))
  assert(buffer.text(buf) == run.after and vim.bo[buf].endofline == eol, 'Redo/newline metadata changed')
end
local buf, run = fixture('original\n', 'proposed\n')
vim.bo[buf].readonly = true
assert(not pcall(buffer.apply, run, buf))
assert(buffer.text(buf) == run.before)
vim.bo[buf].readonly = false
vim.bo[buf].undolevels = -1
assert(not pcall(buffer.apply, run, buf))
assert(buffer.text(buf) == run.before)
vim.bo[buf].undolevels = 1000
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'user edits' })
assert(not pcall(buffer.apply, run, buf))
assert(buffer.text(buf) == 'user edits\n')
local eofbuf, eofrun = fixture('no final newline', 'adds final newline\n')
assert(not pcall(buffer.apply, eofrun, eofbuf), 'Legacy EOF-option changes should not bypass native undo')
assert(buffer.text(eofbuf) == eofrun.before)
vim.cmd 'qa!'
