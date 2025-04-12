if vim.g.loaded_dired then
  return
end

vim.g.loaded_dired = true

vim.api.nvim_create_user_command('Dired', function(opts)
  local path = #opts.args > 0 and vim.fs.abspath(vim.fs.normalize(opts.args)) or vim.uv.cwd()
  require('dired').browse_directory(path)
end, { nargs = '?' })

local highlights = {
  DiredPermissions = { fg = '#4c566a' },
  DiredSize = { fg = '#4c566a' },
  DiredUser = { fg = '#d08770' },
  DiredDate = { fg = '#4c566a' },
  DiredPrompt = { link = 'Keyword' },
  DiredTitle = { link = 'Function' },
  DiredShort = { link = 'DiredPermissions' },
  DiredMatch = { fg = '#268bd2', bold = true },
}

for name, attrs in pairs(highlights) do
  vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', attrs, { default = true }))
end
