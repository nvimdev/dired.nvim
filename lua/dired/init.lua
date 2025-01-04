local api, uv, ffi, joinpath = vim.api, vim.uv, require("ffi"), vim.fs.joinpath

ffi.cdef([[
typedef unsigned int uv_uid_t;
int os_get_uname(uv_uid_t uid, char *s, size_t len);
]])

--- @param fn function
--- @return function
local function curry(fn)
	return function(x)
		return function(y)
			return fn(x, y)
		end
	end
end

local function compose(...)
	local funcs = { ... }
	return function(arg)
		for i = #funcs, 1, -1 do
			arg = funcs[i](arg)
		end
		return arg
	end
end

---@param fn function
---@return function
local function memoize(fn)
	local cache = {}
	return function(key)
		if not cache[key] then
			cache[key] = fn(key)
		end
		return cache[key]
	end
end

---@param value any
---@return table
local function Monad(value)
	return {
		bind = function(self, fn)
			return Monad(fn(self.value))
		end,
		map = function(self, fn)
			return Monad(fn(self.value))
		end,
		value = value,
	}
end

local get_username = memoize(function(user_id)
	local name_out = ffi.new("char[100]")
	ffi.C.os_get_uname(user_id, name_out, 100)
	return ffi.string(name_out)
end)

---@param size integer
---@return string
local function format_size(size)
	if size > 1024 * 1024 * 1024 then
		return string.format("%.2fG", size / (1024 * 1024 * 1024))
	elseif size > 1024 * 1024 then
		return string.format("%.2fM", size / (1024 * 1024))
	elseif size > 1024 then
		return string.format("%.2fK", size / 1024)
	else
		return tostring(size) .. "B"
	end
end

local format_time = compose(
	function(args)
		return os.date(args.fmt, args.timestamp)
	end,
	curry(function(fmt, timestamp)
		return { fmt = fmt, timestamp = timestamp }
	end)("%Y-%m-%d %H:%M")
)

local function parse_permissions(mode)
	local bit = require("bit")
	return table.concat({
		bit.band(mode, 0x100) ~= 0 and "r" or "-",
		bit.band(mode, 0x080) ~= 0 and "w" or "-",
		bit.band(mode, 0x040) ~= 0 and "x" or "-",
		bit.band(mode, 0x020) ~= 0 and "r" or "-",
		bit.band(mode, 0x010) ~= 0 and "w" or "-",
		bit.band(mode, 0x008) ~= 0 and "x" or "-",
		bit.band(mode, 0x004) ~= 0 and "r" or "-",
		bit.band(mode, 0x002) ~= 0 and "w" or "-",
		bit.band(mode, 0x001) ~= 0 and "x" or "-",
	})
end

local render_entry = compose(function(entry)
	return string.format(
		"%-11s %-10s %-10s %-20s %s%s",
		entry.permissions,
		entry.owner,
		entry.size,
		entry.time,
		entry.name,
		entry.file_indicator
	)
end, function(stat)
	return {
		permissions = parse_permissions(stat.mode),
		owner = get_username(stat.uid) or "unknown",
		size = format_size(stat.size),
		time = format_time(stat.mtime.sec),
		name = stat.name,
		file_indicator = stat.file_type == "directory" and "/" or "",
	}
end)

local function set_keymaps(buf, handlers)
	vim.keymap.set("n", "<CR>", handlers.open_entry, { buffer = buf })
	vim.keymap.set("n", "u", handlers.go_up, { buffer = buf })
	vim.keymap.set("n", "q", handlers.close_window, { buffer = buf })
end

local function process_directory(path, callback)
	local handle, err = uv.fs_scandir(path)
	if not handle then
		return callback(nil, { error = err })
	end

	local entries = {}
	local pending = 0
	local completed = false

	local function check_done()
		if pending == 0 and completed then
			vim.schedule(function()
				table.sort(entries, function(a, b)
					local name_a = a:match("%s(%S+)$")
					local name_b = b:match("%s(%S+)$")
					return name_a < name_b
				end)
				callback(entries, nil)
			end)
		end
	end

	while true do
		local name, file_type = uv.fs_scandir_next(handle)
		if not name then
			completed = true
			check_done()
			break
		end

		pending = pending + 1
		uv.fs_stat(joinpath(path, name), function(err, stat)
			if not err then
				Monad(stat):map(function(s)
					s.name = name
					s.file_type = file_type
					return s
				end):bind(function(s)
					table.insert(entries, render_entry(s))
				end)
			end
			pending = pending - 1
			check_done()
		end)
	end
end

local function browse_directory(path)
	api.nvim_buf_set_name(0, ("Dired %s"):format(path))
	process_directory(path, function(entries, err)
		if err then
			return api.nvim_buf_set_lines(0, 2, -1, false, { err.error })
		end
		vim.bo.modifiable = true
		api.nvim_buf_set_lines(0, 2, -1, false, entries)
		vim.bo.modifiable = false
	end)
end

---@class DiredState
---@field buf integer
---@field win integer
---@field path integer

---@return DiredState
local function create_state(path, buf, win)
	return {
		path = path,
		buf = buf,
		win = win,
	}
end

local function create_ui(state)
	local buf = api.nvim_create_buf(false, false)
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 80,
		height = 20,
		row = 5,
		col = 10,
		border = "rounded",
	})
	vim.bo[buf].modifiable = true
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.wo[win].number = false
	vim.wo[win].stc = ""

	local header = string.format("%-10s %-10s %-10s %-20s %s", "Permissions", "Owner", "Size", "Last Modified", "Name")
	api.nvim_buf_set_lines(buf, 0, -1, false, { header, string.rep("-", #header) })
	vim.bo[buf].modifiable = false

	set_keymaps(buf, {
		open_entry = function()
			local line = api.nvim_get_current_line()
			local name = line:match("%s(%S+)$")
			local new_path = joinpath(vim.fn.bufname():gsub("^Dired ", ""), name)
			if vim.fn.isdirectory(new_path) == 1 then
				return browse_directory(new_path)
			end
			api.nvim_win_close(win, true)
			vim.cmd.edit(new_path)
		end,
		go_up = function()
			local path = vim.fn.bufname():gsub("^Dired ", "")
			browse_directory(vim.fs.dirname(vim.fs.normalize(path)))
		end,
		close_window = function()
			api.nvim_win_close(win, true)
		end,
	})
	return create_state(state.path, buf, win)
end

---@param path string
---@return DiredState
local function init_ui_and_browse(path)
	return compose(function(state)
		return browse_directory(state.path)
	end, create_ui)(create_state(path, nil, nil))
end

return { init_ui_and_browse = init_ui_and_browse }
