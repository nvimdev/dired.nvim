local api, uv, ffi, joinpath = vim.api, vim.uv, require('ffi'), vim.fs.joinpath

-- FFI definitions
ffi.cdef([[
typedef unsigned int uv_uid_t;
int os_get_uname(uv_uid_t uid, char *s, size_t len);
]])

-- Functional utilities
local function curry(fn)
  return function(...)
    local args = { ... }
    local nargs = select('#', ...)
    if nargs >= debug.getinfo(fn).nparams then
      return fn(...)
    end
    return function(...)
      local new_args = { ... }
      local all_args = {}
      for i = 1, #args do
        all_args[i] = args[i]
      end
      for i = 1, #new_args do
        all_args[#args + i] = new_args[i]
      end
      return curry(fn)(unpack(all_args))
    end
  end
end

local function pipe(...)
  local fns = { ... }
  return function(x)
    local result = x
    for i = 1, #fns do
      result = fns[i](result)
    end
    return result
  end
end

-- Enhanced memoization with functional interface
local function memoize(fn)
  local cache = {}
  local memoized = setmetatable({}, {
    __call = function(_, ...)
      local key = table.concat({ ... }, ',')
      if not cache[key] then
        cache[key] = fn(...)
      end
      return cache[key]
    end,
  })

  return {
    fn = memoized,
    clear = function(key)
      cache[key] = nil
    end,
    get_cache = function()
      return cache
    end,
  }
end

-- Functional string operations
local String = {
  format = function(fmt)
    return function(...)
      return string.format(fmt, ...)
    end
  end,
  concat = function(sep)
    return function(tbl)
      return table.concat(tbl, sep)
    end
  end,
  pad_right = function(width)
    return function(str)
      return string.format('%-' .. width .. 's', str)
    end
  end,
}

-- Functional array operations
local Array = {
  map = function(fn)
    return function(arr)
      local result = {}
      for i, v in ipairs(arr) do
        result[i] = fn(v)
      end
      return result
    end
  end,
  filter = function(predicate)
    return function(arr)
      local result = {}
      for _, v in ipairs(arr) do
        if predicate(v) then
          table.insert(result, v)
        end
      end
      return result
    end
  end,
  sort = function(comparator)
    return function(arr)
      local sorted = vim.deepcopy(arr)
      table.sort(sorted, comparator)
      return sorted
    end
  end,
}

-- Vim buffer/window options setter
local function set_options(obj_type, options)
  return function(target)
    for key, value in pairs(options) do
      vim[obj_type][target][key] = value
    end
    return target
  end
end

-- Formatting utilities as pure functions
local function create_size_formatter(size)
  local sizes = {
    { limit = 1024 * 1024 * 1024, suffix = 'G', divisor = 1024 * 1024 * 1024 },
    { limit = 1024 * 1024, suffix = 'M', divisor = 1024 * 1024 },
    { limit = 1024, suffix = 'K', divisor = 1024 },
    { limit = 0, suffix = 'B', divisor = 1 },
  }

  return pipe(function(size)
    for _, format in ipairs(sizes) do
      if size > format.limit then
        return { size = size / format.divisor, suffix = format.suffix }
      end
    end
    return { size = size, suffix = 'B' }
  end, function(result)
    return string.format('%.2f%s', result.size, result.suffix)
  end)(size)
end

-- Permission parsing as a pure function pipeline
local function create_permission_parser(mode)
  local bit = require('bit')
  local permissions = {
    { mask = 0x100, char = 'r' },
    { mask = 0x080, char = 'w' },
    { mask = 0x040, char = 'x' },
    { mask = 0x020, char = 'r' },
    { mask = 0x010, char = 'w' },
    { mask = 0x008, char = 'x' },
    { mask = 0x004, char = 'r' },
    { mask = 0x002, char = 'w' },
    { mask = 0x001, char = 'x' },
  }

  return pipe(function(mode)
    return Array.map(function(p)
      return bit.band(mode, p.mask) ~= 0 and p.char or '-'
    end)(permissions)
  end, String.concat(''))(mode)
end

-- Memoized username lookup with functional interface
local get_username = (function()
  local memo = memoize(function(user_id)
    local name_out = ffi.new('char[100]')
    ffi.C.os_get_uname(user_id, name_out, 100)
    return ffi.string(name_out)
  end)
  return memo.fn
end)()

-- Entry rendering as a pure function pipeline
local function create_entry_renderer(name, stat)
  return pipe(function(data)
    return {
      perms = create_permission_parser(data.stat.mode),
      owner = get_username(data.stat.uid) or 'unknown',
      size = create_size_formatter(data.stat.size),
      time = os.date('%Y-%m-%d %H:%M', data.stat.mtime.sec),
      name = data.name .. (data.stat.type == 'directory' and '/' or ''),
    }
  end, function(parts)
    return string.format(
      '%-11s %-10s %-10s %-20s %s',
      parts.perms,
      parts.owner,
      parts.size,
      parts.time,
      parts.name
    )
  end)({ name = name, stat = stat })
end

-- Buffer header setup as a pure function
local function create_buffer_header(buf)
  return pipe(function(b)
    local header = string.format(
      '%-10s %-10s %-10s %-20s %s',
      'Permissions',
      'Owner',
      'Size',
      'Last Modified',
      'Name'
    )
    api.nvim_buf_set_lines(b, 0, -1, false, { header, string.rep('-', #header) })
    return b
  end, set_options('bo', { modifiable = false }))(buf)
end

-- Window creation as a composition of pure functions
local function create_window()
  local calc_dimensions = function()
    local width = math.floor(vim.o.columns * 0.4)
    return {
      width = width,
      height = math.floor(vim.o.lines * 0.5),
      row = math.floor(vim.o.lines / 2) - math.floor(vim.o.lines * 0.25),
      col = math.floor(vim.o.columns / 2) - math.floor(width / 2),
    }
  end

  local dimensions = calc_dimensions()
  local buf = api.nvim_create_buf(false, false)

  local create_win = pipe(
    function()
      return api.nvim_open_win(buf, true, {
        relative = 'editor',
        height = dimensions.height,
        width = dimensions.width,
        row = dimensions.row,
        col = dimensions.col,
        border = 'rounded',
      })
    end,
    set_options('wo', {
      wrap = false,
      number = false,
      stc = '',
    })
  )

  local setup_buf = pipe(
    set_options('bo', {
      modifiable = true,
      buftype = 'nofile',
      bufhidden = 'wipe',
    }),
    create_buffer_header
  )

  return {
    buf = setup_buf(buf),
    win = create_win(),
  }
end

-- Directory refresh as a pure function with side effects
local function create_directory_refresher(state)
  return function(path)
    vim.b[state.buf].current_path = path
    local entries = {}

    local handle, err = uv.fs_scandir(path)
    if not handle then
      vim.notify(('Error opening %s: %s'):format(path, err), vim.log.levels.ERROR)
      return
    end

    local process_entries = pipe(
      Array.sort(function(a, b)
        local name_a = a:match('%s(%S+)$')
        local name_b = b:match('%s(%S+)$')
        return name_a < name_b
      end),
      function(sorted_entries)
        vim.schedule(function()
          vim.bo[state.buf].modifiable = true
          api.nvim_buf_set_lines(state.buf, 2, -1, false, sorted_entries)
          vim.bo[state.buf].modifiable = false
        end)
      end
    )

    local pending = { count = 0 }
    local completed = false

    while true do
      local name = uv.fs_scandir_next(handle)
      if not name then
        completed = true
        if pending.count == 0 then
          process_entries(entries)
        end
        break
      end

      local full_path = joinpath(path, name)
      pending.count = pending.count + 1

      uv.fs_stat(full_path, function(e, stat)
        if not e and stat then
          table.insert(entries, create_entry_renderer(name, stat))
        end
        pending.count = pending.count - 1
        if pending.count == 0 and completed then
          process_entries(entries)
        end
      end)
    end
  end
end

-- Keymap setup as a pure function returning side effects
local function create_keymap_setter(state, refresh_fn)
  return function()
    local keymaps = {
      {
        mode = 'n',
        key = '<CR>',
        action = function()
          local line = api.nvim_get_current_line()
          local name = line:match('%s(%S+)$')
          local new_path = joinpath(vim.b[state.buf].current_path, name)
          if vim.fn.isdirectory(new_path) == 1 then
            refresh_fn(new_path)
          else
            api.nvim_win_close(state.win, true)
            vim.cmd.edit(new_path)
          end
        end,
      },
      {
        mode = 'n',
        key = 'u',
        action = function()
          refresh_fn(vim.fs.dirname(vim.fs.normalize(vim.b[state.buf].current_path)))
        end,
      },
      {
        mode = 'n',
        key = 'q',
        action = function()
          api.nvim_win_close(state.win, true)
        end,
      },
    }

    for _, keymap in ipairs(keymaps) do
      vim.keymap.set(keymap.mode, keymap.key, keymap.action, { buffer = state.buf })
    end
  end
end

-- Main entry point composed of pure functions
local function browse_directory(path)
  local state = create_window()
  local refresh = create_directory_refresher(state)
  create_keymap_setter(state, refresh)()
  refresh(path)
end

return { browse_directory = browse_directory }
