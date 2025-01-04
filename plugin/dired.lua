if vim.g.loaded_dired then
	return
end

vim.g.loaded_dired = true

vim.api.nvim_create_user_command("Dired", function(opts)
	local path = #opts.args > 0 and opts.args or vim.uv.cwd()
	require("dired").init_ui_and_browse(path)
end, { nargs = "?" })
