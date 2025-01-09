local api, uv, ffi = vim.api, vim.uv, require('ffi')

-- FFI definitions
ffi.cdef([[
typedef unsigned int uv_uid_t;
int os_get_uname(uv_uid_t uid, char *s, size_t len);
]])

-- Enhanced functional utilities
local F = {}

-- Either monad for better error handling
F.Either = {
  Left = function(x)
    return { kind = 'Either', tag = 'Left', value = x }
  end,
  Right = function(x)
    return { kind = 'Either', tag = 'Right', value = x }
  end,
  map = function(e, f)
    if e.tag == 'Left' then
      return e
    end
    return F.Either.Right(f(e.value))
  end,
  chain = function(e, f)
    if e.tag == 'Left' then
      return e
    end
    return f(e.value)
  end,
  catch = function(e, f)
    if e.tag == 'Right' then
      return e
    end
    return f(e.value)
  end,
}

-- Enhanced Maybe monad
F.Maybe = {
  of = function(x)
    return { kind = 'Maybe', value = x }
  end,
  nothing = { kind = 'Maybe', value = nil },
  map = function(ma, f)
    if ma.value == nil then
      return F.Maybe.nothing
    end
    return F.Maybe.of(f(ma.value))
  end,
  chain = function(ma, f)
    if ma.value == nil then
      return F.Maybe.nothing
    end
    return f(ma.value)
  end,
  getOrElse = function(ma, default)
    return ma.value or default
  end,
  fromNullable = function(x)
    return x == nil and F.Maybe.nothing or F.Maybe.of(x)
  end,
}

-- Enhanced IO monad
F.IO = {
  of = function(x)
    return {
      kind = 'IO',
      run = function()
        return F.Either.Right(x)
      end,
    }
  end,
  fail = function(error)
    return {
      kind = 'IO',
      run = function()
        return F.Either.Left(error)
      end,
    }
  end,
  fromEffect = function(effect)
    return {
      kind = 'IO',
      run = function()
        local ok, result = pcall(effect)
        if ok then
          return F.Either.Right(result)
        else
          return F.Either.Left(result)
        end
      end,
    }
  end,
  map = function(io, f)
    return {
      kind = 'IO',
      run = function()
        local result = io.run()
        return F.Either.map(result, f)
      end,
    }
  end,
  chain = function(io, f)
    return {
      kind = 'IO',
      run = function()
        local result = io.run()
        return F.Either.chain(result, function(x)
          local next_io = f(x)
          return next_io.run()
        end)
      end,
    }
  end,
  catchError = function(io, handler)
    return {
      kind = 'IO',
      run = function()
        local result = io.run()
        if result.tag == 'Left' then
          return handler(result.value).run()
        end
        return result
      end,
    }
  end,
}

-- Lens implementation
F.Lens = {
  make = function(getter, setter)
    return {
      get = getter,
      set = setter,
      modify = function(f)
        return function(s)
          return setter(s, f(getter(s)))
        end
      end,
    }
  end,
}

-- Pure formatting utilities
local Format = {}

Format.permissions = function(mode)
  local bit = require('bit')
  local function formatSection(r, w, x)
    return table.concat({
      bit.band(mode, r) ~= 0 and 'r' or '-',
      bit.band(mode, w) ~= 0 and 'w' or '-',
      bit.band(mode, x) ~= 0 and 'x' or '-',
    })
  end

  return table.concat({
    formatSection(0x100, 0x080, 0x040),
    formatSection(0x020, 0x010, 0x008),
    formatSection(0x004, 0x002, 0x001),
  })
end

Format.username = function(user_id)
  local name_out = ffi.new('char[100]')
  ffi.C.os_get_uname(user_id, name_out, 100)
  return ffi.string(name_out)
end

Format.size = function(size)
  local units = {
    { limit = 1024 * 1024 * 1024, unit = 'G' },
    { limit = 1024 * 1024, unit = 'M' },
    { limit = 1024, unit = 'K' },
    { limit = 0, unit = 'B' },
  }

  for _, unit in ipairs(units) do
    if size > unit.limit then
      local converted = unit.limit > 0 and size / unit.limit or size
      return string.format('%.2f%s', converted, unit.unit)
    end
  end
  return string.format('%.2f%s', size, 'B')
end

-- UI Components
local UI = {}

UI.Highlights = {
  create_namespace = function()
    return vim.api.nvim_create_namespace('dired_highlights')
  end,

  set_header_highlights = function(bufnr, ns_id)
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, 0, 0, {
      line_hl_group = 'DiredHeader',
      end_row = 0,
    })
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, 1, 0, {
      line_hl_group = 'DiredHeaderLine',
      end_row = 1,
    })
  end,

  set_entry_highlights = function(bufnr, ns_id, line_num, entry)
    local line = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]
    if not line then
      return
    end

    -- permissions
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_num, 0, {
      hl_group = 'DiredPermissions',
      end_col = 10,
    })

    -- user
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_num, 11, {
      hl_group = 'DiredUser',
      end_col = 20,
    })

    -- size
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_num, 21, {
      hl_group = 'DiredSize',
      end_col = 30,
    })

    -- date
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_num, 31, {
      hl_group = 'DiredDate',
      end_col = 50,
    })

    -- filename fh
    local name_start = 55
    local hl_group = 'NormalFloat'

    if entry.stat.type == 'directory' then
      hl_group = 'DiredDirectory'
    elseif entry.stat.type == 'link' then
      hl_group = 'DiredSymlink'
    elseif entry.stat.type == 'file' then
      hl_group = 'DiredFile'
    elseif bit.band(entry.stat.mode, 0x00040) ~= 0 then
      hl_group = 'DiredExecutable'
    end

    vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_num, name_start, {
      hl_group = hl_group,
      end_col = name_start + #entry.name,
    })
  end,
}

UI.Entry = {
  render = function(entry)
    local formatted = {
      perms = Format.permissions(entry.stat.mode),
      user = Format.username(entry.stat.uid),
      size = Format.size(entry.stat.size),
      time = os.date('%Y-%m-%d %H:%M', entry.stat.mtime.sec),
      name = entry.name .. (entry.stat.type == 'directory' and '/' or ''),
    }

    return string.format(
      '%-11s %-10s %-10s %-20s %s',
      formatted.perms,
      formatted.user,
      formatted.size,
      formatted.time,
      formatted.name
    )
  end,
}

UI.Window = {
  create = function(config)
    return F.IO.fromEffect(function()
      local buf = api.nvim_create_buf(false, false)
      local win = api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = config.width,
        height = config.height,
        row = config.row,
        col = config.col,
        border = 'rounded',
      })
      return { buf = buf, win = win }
    end)
  end,

  setup = function(state)
    return F.IO.fromEffect(function()
      vim.bo[state.buf].modifiable = true
      vim.bo[state.buf].buftype = 'nofile'
      vim.bo[state.buf].bufhidden = 'wipe'
      vim.wo[state.win].wrap = false
      vim.wo[state.win].number = false
      vim.wo[state.win].stc = ''

      local header = string.format(
        '%-11s %-10s %-10s %-20s %s',
        'Permissions',
        'Owner',
        'Size',
        'Last Modified',
        'Name'
      )

      api.nvim_buf_set_lines(state.buf, 0, -1, false, {
        header,
        string.rep('-', #header),
      })

      return state
    end)
  end,
}

-- Browser implementation
local Browser = {}

Browser.State = {
  lens = {
    path = F.Lens.make(function(s)
      return s.current_path
    end, function(s, v)
      return vim.tbl_extend('force', s, { current_path = v })
    end),
    entries = F.Lens.make(function(s)
      return s.entries
    end, function(s, v)
      return vim.tbl_extend('force', s, { entries = v })
    end),
  },

  -- Added back the create function
  create = function(path)
    local dimensions = {
      width = math.floor(vim.o.columns * 0.4),
      height = math.floor(vim.o.lines * 0.5),
      row = math.floor((vim.o.lines - math.floor(vim.o.lines * 0.5)) / 2),
      col = math.floor((vim.o.columns - math.floor(vim.o.columns * 0.4)) / 2),
    }

    return F.IO.chain(UI.Window.create(dimensions), function(state)
      return F.IO.chain(UI.Window.setup(state), function(s)
        s.current_path = path
        s.entries = {}
        return F.IO.of(s)
      end)
    end)
  end,
}

Browser.setup = function(state)
  return F.IO.fromEffect(function()
    local keymaps = {
      {
        mode = 'n',
        key = '<CR>',
        action = function()
          local line = api.nvim_get_current_line()
          local name = line:match('%s(%S+)$')
          local current = state.current_path
          local new_path = vim.fs.joinpath(current, name)

          if vim.fn.isdirectory(new_path) == 1 then
            Browser.refresh(state, new_path).run()
            state.current_path = new_path
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
          local current = state.current_path
          local parent = vim.fs.dirname(vim.fs.normalize(current))
          Browser.refresh(state, parent).run()
          state.current_path = parent
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

    vim.iter(keymaps):map(function(map)
      vim.keymap.set(map.mode, map.key, map.action, { buffer = state.buf })
    end)

    return state
  end)
end

Browser.refresh = function(state, path)
  return F.IO.fromEffect(function()
    local handle = uv.fs_scandir(path)
    if not handle then
      vim.notify('Failed to read directory', vim.log.levels.ERROR)
      return
    end
    local ns_id = UI.Highlights.create_namespace()
    local pending = { count = 0 }
    local collected_entries = {}

    while true do
      local name = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      pending.count = pending.count + 1

      local full_path = vim.fs.joinpath(path, name)
      uv.fs_stat(full_path, function(err, stat)
        if not err and stat then
          table.insert(collected_entries, {
            name = name,
            stat = stat,
          })
        end
        pending.count = pending.count - 1

        if pending.count == 0 then
          vim.schedule(function()
            -- Sort entries
            table.sort(collected_entries, function(a, b)
              return a.name < b.name
            end)

            -- Update buffer
            local formatted_entries = vim.tbl_map(function(entry)
              return UI.Entry.render(entry)
            end, collected_entries)

            vim.bo[state.buf].modifiable = true
            api.nvim_buf_set_lines(state.buf, 2, -1, false, formatted_entries)
            vim.bo[state.buf].modifiable = false

            UI.Highlights.set_header_highlights(state.buf, ns_id)
            for i, entry in ipairs(collected_entries) do
              UI.Highlights.set_entry_highlights(state.buf, ns_id, i + 1, entry)
            end
            -- Update state
            state.entries = collected_entries
          end)
        end
      end)
    end

    return state
  end)
end

-- Main entry point
local function browse_directory(path)
  F.IO
    .chain(Browser.State.create(path), function(state)
      return F.IO.chain(Browser.setup(state), function(s)
        return Browser.refresh(s, path)
      end)
    end)
    .run()
end

return { browse_directory = browse_directory }
