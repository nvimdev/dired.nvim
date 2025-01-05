local api, uv, ffi, joinpath = vim.api, vim.uv, require('ffi'), vim.fs.joinpath

ffi.cdef([[
typedef unsigned int uv_uid_t;
int os_get_uname(uv_uid_t uid, char *s, size_t len);
]])

--- Memoization Helper
local function memoize(fn)
  local cache = {}
  return setmetatable({
    get = function(key)
      return cache[key]
    end,
    set = function(key, value)
      cache[key] = value
    end,
    clear = function(key)
      cache[key] = nil
    end,
  }, {
    __call = function(_, key)
      if not cache[key] then
        cache[key] = fn(key)
      end
      return cache[key]
    end,
  })
end

--- Compose Helper
local function compose(...)
  local funcs = { ... }
  return function(arg)
    for i = #funcs, 1, -1 do
      arg = funcs[i](arg)
    end
    return arg
  end
end

--- Memoized Username Lookup
local get_username = memoize(function(user_id)
  local name_out = ffi.new('char[100]')
  ffi.C.os_get_uname(user_id, name_out, 100)
  return ffi.string(name_out)
end)

--- Formatting Utilities
local function format_size(size)
  if size > 1024 * 1024 * 1024 then
    return string.format('%.2fG', size / (1024 * 1024 * 1024))
  elseif size > 1024 * 1024 then
    return string.format('%.2fM', size / (1024 * 1024))
  elseif size > 1024 then
    return string.format('%.2fK', size / 1024)
  else
    return tostring(size) .. 'B'
  end
end

local function parse_permissions(mode)
  local bit = require('bit')
  return table.concat({
    bit.band(mode, 0x100) ~= 0 and 'r' or '-',
    bit.band(mode, 0x080) ~= 0 and 'w' or '-',
    bit.band(mode, 0x040) ~= 0 and 'x' or '-',
    bit.band(mode, 0x020) ~= 0 and 'r' or '-',
    bit.band(mode, 0x010) ~= 0 and 'w' or '-',
    bit.band(mode, 0x008) ~= 0 and 'x' or '-',
    bit.band(mode, 0x004) ~= 0 and 'r' or '-',
    bit.band(mode, 0x002) ~= 0 and 'w' or '-',
    bit.band(mode, 0x001) ~= 0 and 'x' or '-',
  })
end

local function render_entry(name, stat)
  return string.format(
    '%-11s %-10s %-10s %-20s %s%s',
    parse_permissions(stat.mode),
    get_username(stat.uid) or 'unknown',
    format_size(stat.size),
    os.date('%Y-%m-%d %H:%M', stat.mtime.sec),
    name,
    stat.type == 'directory' and '/' or ''
  )
end

local function apply_options(obj_type)
  return function(options)
    return function(target)
      for key, value in pairs(options) do
        vim[obj_type][target][key] = value
      end
      return target
    end
  end
end

local function set_buffer_header(buf)
  local header = string.format(
    '%-10s %-10s %-10s %-20s %s',
    'Permissions',
    'Owner',
    'Size',
    'Last Modified',
    'Name'
  )
  api.nvim_buf_set_lines(buf, 0, -1, false, { header, string.rep('-', #header) })
  vim.bo[buf].modifiable = false
  return buf
end

local function create_window()
  local buf = api.nvim_create_buf(false, false)
  local width = math.floor(vim.o.columns * 0.4)
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    height = math.floor(vim.o.lines * 0.5),
    width = width,
    row = math.floor(vim.o.lines / 2) - math.floor(vim.o.lines * 0.25),
    col = math.floor(vim.o.columns / 2) - math.floor(width / 2),
    border = 'rounded',
  })

  compose(
    apply_options('bo')({
      modifiable = true,
      buftype = 'nofile',
      bufhidden = 'wipe',
    }),
    set_buffer_header
  )(buf)

  apply_options('wo')({
    wrap = false,
    number = false,
    stc = '',
  })(win)

  return { buf = buf, win = win }
end

--- Asynchronous Directory Refresh
local function refresh_directory(state, path)
  api.nvim_buf_set_name(state.buf, ('Dired %s'):format(path))
  local entries = {}
  local handle, err = uv.fs_scandir(path)

  if not handle then
    vim.notify(('Error opening %s: %s'):format(path, err), vim.log.levels.ERROR)
    return
  end

  local pending = 0
  local completed = false

  local function finalize()
    if pending == 0 and completed then
      table.sort(entries, function(a, b)
        local name_a = a:match('%s(%S+)$')
        local name_b = b:match('%s(%S+)$')
        return name_a < name_b
      end)
      vim.schedule(function()
        vim.bo[state.buf].modifiable = true
        api.nvim_buf_set_lines(state.buf, 2, -1, false, entries)
        vim.bo[state.buf].modifiable = false
      end)
    end
  end

  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      completed = true
      finalize()
      break
    end

    local full_path = joinpath(path, name)
    pending = pending + 1

    uv.fs_stat(full_path, function(e, stat)
      if not e and stat then
        table.insert(entries, render_entry(name, stat))
      end
      pending = pending - 1
      finalize()
    end)
  end
end

--- Keymap Setup as Pure Function
local function set_keymaps(state, refresh_fn)
  local buf, win = state.buf, state.win

  vim.keymap.set('n', '<CR>', function()
    local line = api.nvim_get_current_line()
    local name = line:match('%s(%S+)$')
    local new_path = joinpath(vim.fn.bufname():gsub('^Dired ', ''), name)
    if vim.fn.isdirectory(new_path) == 1 then
      refresh_fn(new_path)
    else
      api.nvim_win_close(win, true)
      vim.cmd.edit(new_path)
    end
  end, { buffer = buf })

  vim.keymap.set('n', 'u', function()
    local curpath = vim.fn.bufname():gsub('^Dired ', '')
    refresh_fn(vim.fs.dirname(curpath))
  end, { buffer = buf })

  vim.keymap.set('n', 'q', function()
    api.nvim_win_close(win, true)
  end, { buffer = buf })
end

--- Main Entry
local function browse_directory(path)
  local state = create_window()
  set_keymaps(state, function(new_path)
    refresh_directory(state, new_path)
  end)
  refresh_directory(state, path)
end

return { browse_directory = browse_directory }
