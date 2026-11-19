-- Neovim owns text, saving, and undo. The runner only proposes replacements.
local M = {}

function M.text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. (vim.bo[buf].endofline and '\n' or '')
end

function M.supported(buf)
  return vim.bo[buf].fileformat == 'unix' and not vim.bo[buf].bomb
    and (vim.bo[buf].fileencoding == '' or vim.bo[buf].fileencoding == 'utf-8')
end

local function lines(text)
  local result = vim.split(text, '\n', { plain = true })
  if text:sub(-1) == '\n' then table.remove(result) end
  if #result == 0 then result = { '' } end
  return result
end

function M.apply(run, buf)
  assert(run.status == 'proposed', 'Only a proposed change can be accepted')
  assert(buf and vim.api.nvim_buf_is_loaded(buf), 'Open the source buffer before accepting')
  local name = vim.api.nvim_buf_get_name(buf)
  assert(vim.fs.normalize(name) == run.file or vim.uv.fs_realpath(name) == run.file, 'Source buffer was renamed')
  assert(M.supported(buf), 'Buffer edits require UTF-8/Unix text without a BOM')
  assert(vim.bo[buf].modifiable and not vim.bo[buf].readonly, 'Source is readonly or nonmodifiable')
  assert(M.text(buf) == run.before, 'Source buffer changed since this proposal; request again')
  assert(type(run.after) == 'string', 'Missing replacement text')
  assert((run.before:sub(-1) == '\n') == (run.after:sub(-1) == '\n'),
    'This older proposal changes the final-newline option; request it again')
  local levels = vim.bo[buf].undolevels
  if levels == -123456 then levels = vim.go.undolevels end
  assert(levels >= 0, 'Undo is disabled for this buffer; enable it before accepting')
  if run.before == run.after then return end
  local old, new = lines(run.before), lines(run.after)
  local first, last_old, last_new = 1, #old, #new
  while first <= last_old and first <= last_new and old[first] == new[first] do first = first + 1 end
  while last_old >= first and last_new >= first and old[last_old] == new[last_new] do
    last_old, last_new = last_old - 1, last_new - 1
  end
  vim.api.nvim_buf_call(buf, function()
    -- Close, do not join, undo blocks; preserve both local and global option values.
    vim.cmd 'let &g:undolevels = &g:undolevels'
    vim.api.nvim_buf_set_lines(buf, first - 1, last_old, false, vim.list_slice(new, first, last_new))
    vim.cmd 'let &g:undolevels = &g:undolevels'
  end)
end

return M
