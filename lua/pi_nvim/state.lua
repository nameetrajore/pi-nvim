-- UI identity survives code reloads; active processes are owned by init.lua.
return {
  panels = {},
  by_id = {},
  source_panel = {},
  inline_keys = {},
  sequence = 0,
  namespace = vim.api.nvim_create_namespace 'pi-nvim-requests',
}
