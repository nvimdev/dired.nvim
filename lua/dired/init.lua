local api, uv, ffi = vim.api, vim.uv, require('ffi')
local mapset = vim.keymap.set
local ops = require('dired.ops')
local FileOps, PathOps = ops.FileOps, ops.PathOps
local ns_id = api.nvim_create_namespace('dired_highlights')
local ns_mark = api.nvim_create_namespace('dired_marks')
local ns_entry = api.nvim_create_namespace('dired_entries')
local SEPARATOR = '/'
local IS_WIN = vim.fn.has('win32') == 1

-- FFI definitions
ffi.cdef([[
typedef unsigned int uv_uid_t;
int os_get_uname(uv_uid_t uid, char *s, size_t len);
]])

---@class KeyMapConfig
---@field open string|table<string, string>
---@field up string|table<string, string>
---@field quit string|table<string, string>
---@field toggle_hidden string|table<string, string>
---@field forward string|table<string, string>
---@field backward string|table<string, string>
---@field split string|table<string, string>
---@field vsplit string|table<string, string>
---@field switch string|table<string, string>
---@field open_cur string|table<string, string>

---@class DiredConfig
---@field shortcuts string
---@field show_hidden boolean
---@field show_user boolean
---@field normal_when_fits boolean
---@field use_trash boolean
---@field confirm_delete boolean
---@field search_depth integer
---@field search_max_files integer
---@field keymaps KeyMapConfig

local DEFAULTS = {
  show_hidden = true,
  normal_when_fits = false,
  shortcuts = 'sdfhlwertyuopzxcvbnmSDFGHLQWERTYUOPZXCVBNM',
  show_user = false,
  use_trash = true,
  confirm_delete = true,
  search_depth = 5,
  search_max_files = 20000,
  keymaps = {
    open = { i = '<CR>', n = '<CR>' }, -- both on search and main buffer
    up = { i = '<C-u>', n = '<C-u>' }, -- both on search and main buffer
    quit = { n = { 'q', '<ESC>' }, i = '<C-c>' }, -- both on search and main buffer
    forward = { i = '<C-n>', n = 'j' }, -- search buffer
    backward = { i = '<C-p>', n = 'k' }, -- search buffer
    split = { n = 'gs', i = '<C-s>' }, -- both on search and main buffer
    vsplit = { n = 'gv', i = '<C-v>' }, -- both on search and main buffer
    switch = { i = '<C-j>', n = '<C-j>' }, -- both on search and main buffer
    open_cur = { i = '<C-g>' },
    toggle_hidden = { n = 'g.' }, -- both on search and main buffer
  },
}

---@type DiredConfig
local Config = setmetatable({}, {
  __index = function(_, scope)
    local user = vim.g.dired or {}
    if scope == 'keymaps' then
      local km = vim.tbl_extend('force', DEFAULTS.keymaps, user.keymaps or {})
      if user.keymaps and user.keymaps.toogle_hidden and not user.keymaps.toggle_hidden then
        km.toggle_hidden = user.keymaps.toogle_hidden
      end
      return km
    end
    if user[scope] ~= nil then
      return user[scope]
    end
    return DEFAULTS[scope]
  end,
})

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
        return F.Either[ok and 'Right' or 'Left'](result)
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

local username_cache = {}
Format.username = function(user_id)
  if username_cache[user_id] then
    return username_cache[user_id]
  end
  local ok, name = pcall(function()
    local name_out = ffi.new('char[100]')
    if ffi.C.os_get_uname(user_id, name_out, 100) == 0 then
      return nil
    end
    return ffi.string(name_out)
  end)
  name = (ok and name and name ~= '') and name or tostring(user_id)
  username_cache[user_id] = name
  return name
end

Format.size = function(size)
  local units = {
    { limit = 1024 * 1024 * 1024, unit = 'G' },
    { limit = 1024 * 1024, unit = 'M' },
    { limit = 1024, unit = 'K' },
    { limit = 0, unit = 'B' },
  }

  for _, unit in ipairs(units) do
    if unit.limit > 0 and size >= unit.limit then
      local converted = unit.limit > 0 and size / unit.limit or size
      return string.format('%.2f%s', converted, unit.unit)
    end
  end
  return string.format('%.2f%s', size, 'B')
end

Format.friendly_time = function(timestamp)
  local now = os.time()
  local diff = now - timestamp
  if diff < 0 then
    return os.date('%Y %b %d %H:%M', timestamp)
  elseif diff < 60 then
    return string.format('%d secs ago', diff)
  elseif diff < 3600 then
    return string.format('%d mins ago', math.floor(diff / 60))
  elseif diff < 86400 then
    return string.format('%d hours ago', math.floor(diff / 3600))
  elseif diff < 86400 * 14 then -- two weeks show "X days ago"
    return string.format('%d days ago', math.floor(diff / 86400))
  else
    return os.date('%Y %b %d', timestamp)
  end
end

-- Notification system
local function notify_wrapper(level)
  return function(msg)
    vim.schedule(function()
      vim.notify(msg, level)
    end)
  end
end

local Notify = {}
Notify.err = notify_wrapper(vim.log.levels.ERROR)
Notify.info = notify_wrapper(vim.log.levels.INFO)

-- UI Components
local UI = {}
-- Browser implementation
local Browser = {}
local Actions = {}

local function display_name(entry)
  return entry.name .. (entry.stat.type == 'directory' and SEPARATOR or '')
end

local function without_undo(buf, fn)
  local ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  local ok, err = pcall(fn)
  vim.bo[buf].undolevels = ul
  if not ok then
    error(err)
  end
end

UI.Entry = {
  line = function(_, entry)
    return display_name(entry)
  end,
  render = function(state, row, entry)
    local formatted = {
      perms = entry.perms or Format.permissions(entry.stat.mode),
      user = entry.user or Format.username(entry.stat.uid),
      size = entry.size or Format.size(entry.stat.size),
      time = entry.date or Format.friendly_time(entry.stat.mtime.sec),
    }
    local texts = {
      { ('%-11s '):format(formatted.perms), 'DiredPermissions' },
      { ('%-10s '):format(formatted.size), 'DiredSize' },
      { ('%-20s '):format(formatted.time), 'DiredDate' },
    }
    if Config.show_user then
      table.insert(texts, 2, { ('%-10s '):format(formatted.user), 'DiredUser' })
    end

    api.nvim_buf_set_extmark(state.buf, ns_id, row, 0, {
      hl_mode = 'combine',
      virt_text = texts,
      virt_text_win_col = (state.maxwidth or 0) + 6,
      right_gravity = false,
    })

    local id = api.nvim_buf_set_extmark(state.buf, ns_entry, row, 0, {
      invalidate = true,
      right_gravity = true,
    })
    state.mark_entry[id] = entry

    if entry.match_pos then
      for _, col in ipairs(entry.match_pos) do
        api.nvim_buf_set_extmark(state.buf, ns_id, row, col, {
          end_col = col + 1,
          hl_group = 'DiredMatch',
          hl_mode = 'combine',
        })
      end
    end
  end,
}

UI.Window = {
  create = function(config)
    return F.IO.fromEffect(function()
      -- Create search window
      local search_buf = api.nvim_create_buf(false, false)
      vim.bo[search_buf].buftype = 'prompt'
      vim.bo[search_buf].bufhidden = 'wipe'
      vim.fn.prompt_setprompt(search_buf, '')
      vim.b[search_buf].curbuf = api.nvim_get_current_buf()
      local origin_win = api.nvim_get_current_win()
      local search_win = api.nvim_open_win(search_buf, true, {
        relative = 'editor',
        width = config.width,
        height = 1,
        row = config.row - 2,
        border = {
          '╭',
          '─',
          '╮',
          '│',
          '╯',
          '',
          '╰',
          '│',
        },
        col = config.col,
        style = 'minimal',
      })
      vim.wo[search_win].wrap = false
      local buf = api.nvim_create_buf(false, true)
      vim.bo[buf].modifiable = true
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].textwidth = 2000

      local height = math.min(math.floor(vim.o.lines * 0.5), 25)
      local win = api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = config.width,
        height = height, -- make sure less than length of shortcuts count
        row = config.row,
        col = config.col,
        border = {
          '│',
          { ' ', 'NormalFloat' },
          '│',
          '│',
          '╯',
          '─',
          '╰',
          '│',
        },
        style = 'minimal',
      })

      vim.wo[win].fillchars = 'eob: '
      vim.wo[win].list = false
      vim.wo[win].cursorline = true
      return {
        search_buf = search_buf,
        search_win = search_win,
        buf = buf,
        win = win,
        origin_win = origin_win,
      }
    end)
  end,
  event = function(state)
    return F.IO.fromEffect(function()
      state.group = api.nvim_create_augroup('DiredGroup', {})

      local function cleanup()
        if state.closed then
          return
        end
        state.closed = true
        if state.search_engine then
          state.search_engine.destroy()
        end
        pcall(api.nvim_del_augroup_by_id, state.group)
        vim.schedule(function()
          pcall(api.nvim_win_close, state.search_win, true)
          pcall(api.nvim_win_close, state.win, true)
        end)
      end
      state.cleanup = cleanup
      api.nvim_create_autocmd('WinClosed', {
        group = state.group,
        pattern = { tostring(state.win), tostring(state.search_win) },
        callback = cleanup,
      })

      api.nvim_create_autocmd('CursorMoved', {
        group = state.group,
        buffer = state.buf,
        callback = function()
          if
            not api.nvim_buf_is_valid(state.search_buf) or not api.nvim_win_is_valid(state.win)
          then
            return
          end
          local row = api.nvim_win_get_cursor(state.win)[1] - 1
          state.count_mark = api.nvim_buf_set_extmark(state.search_buf, ns_id, 0, 0, {
            id = state.count_mark or nil,
            virt_text = {
              {
                ('[%d/%d]   Find File: '):format(row + 1, state.total_count or #state.entries),
                'DiredTitle',
              },
            },
            virt_text_pos = 'inline',
          })

          if api.nvim_win_is_valid(state.win) then
            state.shortcut_manager.recycle(state)
          end
        end,
      })

      api.nvim_create_autocmd({ 'InsertLeave', 'TextChanged' }, {
        group = state.group,
        buffer = state.buf,
        callback = function()
          vim.schedule(function()
            Browser.applyChanges(state)
          end)
        end,
      })
      api.nvim_create_autocmd('WinLeave', {
        group = state.group,
        buffer = state.buf,
        callback = function()
          vim.schedule(function()
            Browser.applyChanges(state)
          end)
        end,
      })

      api.nvim_create_autocmd('TextYankPost', {
        group = state.group,
        buffer = state.buf,
        callback = function()
          if vim.v.event.operator ~= 'y' then
            return
          end
          local s = api.nvim_buf_get_mark(state.buf, '[')[1]
          local e = api.nvim_buf_get_mark(state.buf, ']')[1]
          local list = Browser.entriesInRange(state, s, e)
          if #list > 0 then
            state.clipboard = { type = 'copy', entries = list, source_path = state.current_path }
            Notify.info(('copied %d item(s)'):format(#list))
          end
        end,
      })
      return state
    end)
  end,
  monitor = function(state)
    return F.IO.fromEffect(function()
      state.clipboard = {}

      local function exit_visual()
        api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
      end

      local function cut(list)
        if #list == 0 then
          return
        end
        state.clipboard = { type = 'cut', entries = list, source_path = state.current_path }
        Notify.info(('cut %d item(s), press p to move here'):format(#list))
      end

      local function opts(desc)
        return { buffer = state.buf, nowait = true, desc = 'dired: ' .. desc }
      end
      local function paste()
        Browser.executeClipboardOperation(state)
      end
      mapset('n', 'p', paste, opts('paste clipboard'))
      mapset('n', 'P', paste, opts('paste clipboard'))
      mapset('n', 'D', function()
        local l = api.nvim_win_get_cursor(0)[1]
        cut(Browser.entriesInRange(state, l, l + vim.v.count1 - 1))
      end, opts('cut'))
      for _, lhs in ipairs({ 'd', 'D', 'x' }) do
        mapset('x', lhs, function()
          local a, b = vim.fn.line('v'), vim.fn.line('.')
          exit_visual()
          cut(Browser.entriesInRange(state, a, b))
        end, opts('cut selection'))
      end
      for _, lhs in ipairs({ 'p', 'P' }) do
        mapset('x', lhs, exit_visual, opts('disabled'))
      end

      return state
    end)
  end,
}

Browser.executeClipboardOperation = function(state)
  if not state.clipboard or not state.clipboard.entries or #state.clipboard.entries == 0 then
    Notify.info('clipboard is empty')
    return
  end

  local operations = {}
  local destination_path = state.current_path
  local source_path = state.clipboard.source_path

  local function exists(p)
    return uv.fs_lstat(p) ~= nil
  end

  for _, entry in ipairs(state.clipboard.entries) do
    local source_name = vim.fs.basename(entry.name)
    local full_source_path = vim.fs.joinpath(source_path, entry.name)
    local target_path = vim.fs.joinpath(destination_path, source_name)

    if full_source_path == target_path and state.clipboard.type == 'copy' then
      local extension = source_name:match('^.+(%.[^.]+)$') or ''
      local base_name = source_name:sub(1, #source_name - #extension)

      local i = 1
      local new_name = base_name .. '_copy' .. extension
      target_path = vim.fs.joinpath(destination_path, new_name)

      while exists(target_path) do
        i = i + 1
        new_name = base_name .. '_copy' .. i .. extension
        target_path = vim.fs.joinpath(destination_path, new_name)
      end
    end

    if full_source_path == target_path then
      Notify.info('source and target are same: ' .. source_name)
      goto continue
    end

    if exists(target_path) then
      Notify.err('target path exists: ' .. target_path)
      goto continue
    end

    table.insert(operations, {
      type = state.clipboard.type, -- 'copy' or 'cut'
      source = full_source_path,
      target = target_path,
      is_directory = entry.stat.type == 'directory',
      name = source_name,
    })

    ::continue::
  end

  if #operations == 0 then
    Notify.info('no any pending operations')
    return
  end

  Browser.executeClipboardOperations(state, operations)
end

Browser.executeClipboardOperations = function(state, operations)
  local total = #operations
  local completed = 0
  local errors = {}

  local function updateStatus()
    if #errors > 0 then
      Notify.err(string.format('operation done, %d errors', #errors))
      for _, err in ipairs(errors) do
        Notify.err(err)
      end
    else
      local action = state.clipboard.type == 'copy' and 'copy' or 'move'
      Notify.info(string.format('Successfully %s %d files', action, total))
    end

    if state.clipboard.type == 'cut' then
      state.clipboard = {}
    end

    Browser.refresh(state, state.current_path).run()
  end

  local function executeNextOperation(index)
    if index > #operations then
      updateStatus()
      return
    end

    local op = operations[index]

    if op.type == 'copy' then
      local task = FileOps.copy(op.source, op.target)
      task.fork(function(err)
        table.insert(errors, string.format('copied failed: %s: %s', op.name, err))
        vim.schedule(function()
          executeNextOperation(index + 1)
        end)
      end, function()
        completed = completed + 1
        vim.schedule(function()
          executeNextOperation(index + 1)
        end)
      end)
    elseif op.type == 'cut' then
      local task = FileOps.moveAcross(op.source, op.target)
      task.fork(function(err)
        table.insert(errors, string.format('moved failed: %s: %s', op.name, err))
        vim.schedule(function()
          executeNextOperation(index + 1)
        end)
      end, function()
        completed = completed + 1
        vim.schedule(function()
          executeNextOperation(index + 1)
        end)
      end)
    end
  end

  executeNextOperation(1)
end

local function shortcut_pool()
  local reserved = { G = true }
  for _, spec in pairs(Config.keymaps) do
    local n = type(spec) == 'table' and spec.n or (type(spec) == 'string' and spec or nil)
    for _, k in ipairs(type(n) == 'table' and n or { n }) do
      if type(k) == 'string' and #k == 1 then
        reserved[k] = true
      end
    end
  end
  return vim.tbl_filter(function(k)
    return not reserved[k]
  end, vim.split(Config.shortcuts, ''))
end

local function create_shortcut_manager()
  local pool = shortcut_pool()
  -- {shortcut -> line_num}
  local assigned = {} -- type table<string, int>

  return {
    get = function()
      return assigned
    end,
    reset = function(state)
      for shortcut, _ in pairs(assigned) do
        pcall(vim.keymap.del, 'n', shortcut, { buffer = state.search_buf })
      end
      assigned = {}
      pool = shortcut_pool()
      if api.nvim_buf_is_valid(state.buf) then
        api.nvim_buf_clear_namespace(state.buf, ns_mark, 0, -1)
      end
    end,
    assign = function(state, row)
      local key = select(1, unpack(pool))
      if key then
        assigned[key] = row + 1
        api.nvim_buf_set_extmark(state.buf, ns_mark, row, 0, {
          hl_group = 'DiredShort',
          virt_text_pos = 'inline',
          virt_text = { { ('[%s] '):format(key), 'DiredShort' } },
          invalidate = true,
          right_gravity = false,
        })
        pool = { unpack(pool, 2) }
        mapset('n', key, function()
          local lnum = assigned[key]
          local text = api.nvim_buf_get_lines(state.buf, lnum - 1, lnum, false)[1]
          if text then
            text = text:gsub('%s+$', '')
            local path = vim.fs.joinpath(state.current_path, text)
            if PathOps.isDirectory(path) then
              Actions.openDirectory(state, path).run()
            elseif PathOps.isFile(path) then
              Actions.openFile(state, path, function(p)
                vim.cmd.edit(p)
              end)
            end
          end
        end, { buffer = state.search_buf })
      end
      return key
    end,

    recycle = function(state)
      if not api.nvim_buf_is_valid(state.buf) or not api.nvim_win_is_valid(state.win) then
        return
      end

      local visible = api.nvim_win_call(state.win, function()
        local top = vim.fn.line('w0')
        local bot = vim.fn.line('w$')
        return { top, bot }
      end)

      if visible[1] > visible[2] then
        for key, _ in pairs(assigned) do
          pcall(vim.keymap.del, 'n', key, { buffer = state.search_buf })
          table.insert(pool, key)
        end
        assigned = {}
        api.nvim_buf_clear_namespace(state.buf, ns_mark, 0, -1)
        return
      end

      local keys_to_recycle = {}
      local new_assigned = {}
      local assigned_lines = {}

      for key, lnum in pairs(assigned) do
        if lnum < visible[1] or lnum > visible[2] then
          table.insert(keys_to_recycle, key)
          pcall(vim.keymap.del, 'n', key, { buffer = state.search_buf })
          pcall(function()
            local extmarks = api.nvim_buf_get_extmarks(
              state.buf,
              ns_mark,
              { lnum - 1, 0 },
              { lnum - 1, -1 },
              {}
            )
            for _, mark in ipairs(extmarks) do
              api.nvim_buf_del_extmark(state.buf, ns_mark, mark[1])
            end
          end)
        else
          new_assigned[key] = lnum
          assigned_lines[lnum] = key
        end
      end

      assigned = new_assigned

      for _, key in ipairs(keys_to_recycle) do
        table.insert(pool, key)
      end

      table.sort(pool, function(a, b)
        local shortcuts = Config.shortcuts
        return shortcuts:find(a, 1, true) < shortcuts:find(b, 1, true)
      end)

      local total_lines = api.nvim_buf_line_count(state.buf)
      local lines_to_assign = {}

      for lnum = visible[1], math.min(visible[2], total_lines) do
        if not assigned_lines[lnum] then
          table.insert(lines_to_assign, lnum)
        end
      end

      for _, lnum in ipairs(lines_to_assign) do
        if #pool > 0 then
          local key = table.remove(pool, 1)
          assigned[key] = lnum
          pcall(function()
            api.nvim_buf_set_extmark(state.buf, ns_mark, lnum - 1, 0, {
              hl_group = 'DiredShort',
              virt_text_pos = 'inline',
              virt_text = { { ('[%s] '):format(key), 'DiredShort' } },
              invalidate = true,
              right_gravity = false,
            })
          end)

          pcall(function()
            mapset(
              'n',
              key,
              (function(target_lnum)
                return function()
                  if not api.nvim_buf_is_valid(state.buf) then
                    return
                  end

                  local success, text = pcall(function()
                    return api.nvim_buf_get_lines(state.buf, target_lnum - 1, target_lnum, false)[1]
                  end)

                  if success and text then
                    text = text:gsub('%s+$', '')
                    local path = vim.fs.joinpath(state.current_path, text)
                    if PathOps.isDirectory(path) then
                      Actions.openDirectory(state, path).run()
                    elseif PathOps.isFile(path) then
                      Actions.openFile(state, path, function(p)
                        vim.cmd.edit(p)
                      end)
                    end
                  end
                end
              end)(lnum),
              { buffer = state.search_buf }
            )
          end)
        else
          break
        end
      end
    end,
  }
end

local MAX_RESULTS = 80

local function find_fd()
  if vim.fn.executable('fd') == 1 then
    return 'fd'
  elseif vim.fn.executable('fdfind') == 1 then
    return 'fdfind'
  end
end

local function create_debounced_search()
  local timer = nil
  local job = nil
  local gen = 0
  local cache = nil -- { path, names, loading, waiters }

  local function stop_timer()
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      timer = nil
    end
  end

  local function kill_job()
    if job then
      pcall(function()
        job:kill(9)
      end)
      job = nil
    end
  end

  local function walk_lua(path)
    local names = {}
    local max = Config.search_max_files
    for name, _ in
      vim.fs.dir(path, {
        depth = Config.search_depth,
        skip = function(dir)
          local base = vim.fs.basename(dir)
          return base ~= '.git' and base ~= 'node_modules'
        end,
      })
    do
      table.insert(names, name)
      if #names >= max then
        break
      end
    end
    return names
  end

  local function list_files(path, cb)
    if cache and cache.path == path then
      if cache.names then
        return cb(cache.names)
      end
      table.insert(cache.waiters, cb)
      return
    end
    kill_job()
    local my = { path = path, waiters = { cb } }
    cache = my

    local function done(names)
      if cache ~= my then
        return
      end
      my.names = names
      local waiters = my.waiters
      my.waiters = {}
      for _, w in ipairs(waiters) do
        w(names)
      end
    end

    local fd = find_fd()
    if not fd then
      vim.schedule(function()
        done(walk_lua(path))
      end)
      return
    end

    local ok, obj = pcall(vim.system, {
      fd,
      '--hidden',
      '--exclude',
      '.git',
      '--max-depth',
      tostring(Config.search_depth),
      '--max-results',
      tostring(Config.search_max_files),
      '--color',
      'never',
      '--print0',
    }, { cwd = path, text = true }, function(res)
      vim.schedule(function()
        if cache ~= my then
          return
        end
        job = nil
        if res.code ~= 0 and (res.stdout or '') == '' then
          Notify.err('Search error: ' .. (res.stderr or ('exit ' .. res.code)))
          return done({})
        end
        local names = {}
        for _, name in ipairs(vim.split(res.stdout or '', '\0', { plain = true })) do
          if name ~= '' then
            name = name:gsub('^%./', ''):gsub('[/\\]+$', '')
            if IS_WIN then
              name = name:gsub('\\', '/')
            end
            table.insert(names, name)
          end
        end
        done(names)
      end)
    end)
    if ok then
      job = obj
    else
      vim.schedule(function()
        done(walk_lua(path))
      end)
    end
  end

  local function run(state, query, callback, my_gen)
    local path = state.current_path
    list_files(path, function(names)
      if my_gen ~= gen or state.closed or state.current_path ~= path then
        return
      end
      local res = vim.fn.matchfuzzypos(names, query)
      local matched, positions = res[1], res[2]
      local results = {}
      for i = 1, math.min(#matched, MAX_RESULTS) do
        local name = matched[i]
        local full = vim.fs.joinpath(path, name)
        local stat = uv.fs_stat(full) or uv.fs_lstat(full)
        if stat then
          local cols = {}
          for _, ci in ipairs(positions[i]) do
            table.insert(cols, vim.fn.byteidx(name, ci))
          end
          table.insert(results, { name = name, stat = stat, match_pos = cols })
        end
      end
      callback(results, #matched)
    end)
  end

  return {
    search = function(state, query, callback, delay)
      stop_timer()
      gen = gen + 1
      local my_gen = gen
      timer = assert(uv.new_timer())
      timer:start(
        delay or 100,
        0,
        vim.schedule_wrap(function()
          stop_timer()
          if my_gen == gen and not state.closed then
            run(state, query, callback, my_gen)
          end
        end)
      )
    end,
    reset = function()
      gen = gen + 1
      stop_timer()
      kill_job()
      cache = nil
    end,
    destroy = function()
      gen = gen + 1
      stop_timer()
      kill_job()
      cache = nil
    end,
  }
end

Browser.State = {
  create = function(path)
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.min(math.floor(vim.o.lines * 0.5), 25)
    local dimensions = {
      width = width,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
    }

    return F.IO.chain(UI.Window.create(dimensions), function(state)
      return F.IO.chain(UI.Window.event(state), function(s)
        ---@diagnostic disable-next-line: redefined-local
        return F.IO.chain(UI.Window.monitor(s), function(s)
          s.current_path = path
          s.entries = {}
          s.show_hidden = Config.show_hidden
          s.clipboard = {}
          s.shortcut_manager = create_shortcut_manager()
          s.search_engine = create_debounced_search()
          s.searching = false
          s.refresh_id = 0
          s.mark_entry = {}

          local function windows_valid()
            return not s.closed
              and api.nvim_buf_is_valid(s.buf)
              and api.nvim_win_is_valid(s.win)
              and api.nvim_buf_is_valid(s.search_buf)
              and api.nvim_win_is_valid(s.search_win)
          end
          s.windows_valid = windows_valid

          local function set_title(cur, total)
            s.count_mark = api.nvim_buf_set_extmark(s.search_buf, ns_id, 0, 0, {
              id = s.count_mark,
              virt_text = { { ('[%d/%d]   Find File: '):format(cur, total), 'DiredTitle' } },
              virt_text_pos = 'inline',
            })
          end

          -- Function to update display with entries
          local function update_display(_, entries_to_show, change_mode, total)
            vim.schedule(function()
              if not windows_valid() then
                return
              end
              local buf = s.buf
              s.shortcut_manager.reset(s)

              local lines = {}
              for i, entry in ipairs(entries_to_show) do
                lines[i] = UI.Entry.line(s, entry)
              end

              vim.bo[buf].modifiable = true
              without_undo(buf, function()
                api.nvim_buf_set_lines(buf, 0, -1, false, lines)
              end)
              api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
              api.nvim_buf_clear_namespace(buf, ns_entry, 0, -1)
              s.mark_entry = {}
              for i, entry in ipairs(entries_to_show) do
                UI.Entry.render(s, i - 1, entry)
              end
              vim.bo[buf].modifiable = true
              vim.bo[buf].modified = false
              s.render_tick = api.nvim_buf_get_changedtick(buf)
              s.applying = false
              s.total_count = total or #entries_to_show

              set_title(#entries_to_show > 0 and 1 or 0, s.total_count)

              local lnum
              if s.target_op then
                for i, entry in ipairs(entries_to_show) do
                  if entry.name == s.target_op.name then
                    lnum = i
                    break
                  end
                end
                s.target_op = nil
              end
              if not lnum and s.before_pos then
                lnum = s.before_pos[1]
              end
              s.before_pos = nil
              lnum = math.max(1, math.min(lnum or 1, api.nvim_buf_line_count(buf)))
              api.nvim_win_set_cursor(s.win, { lnum, 0 })

              for i = 1, #entries_to_show do
                s.shortcut_manager.assign(s, i - 1)
              end

              if change_mode == nil then
                change_mode = true
              end
              if
                change_mode
                and Config.normal_when_fits
                and #entries_to_show <= api.nvim_win_get_height(s.win)
              then
                api.nvim_feedkeys(api.nvim_replace_termcodes('<ESC>', true, false, true), 'n', true)
              end
            end)
          end
          s.update_display = update_display

          local function on_prompt_changed()
            if not windows_valid() then
              return
            end
            local line = api.nvim_buf_get_lines(s.search_buf, 0, 1, false)[1] or ''
            if line == s.last_line and not s.searching then
              return
            end

            if s.last_line and line .. SEPARATOR == s.last_line then
              local parent = vim.fs.dirname(vim.fs.normalize(s.last_line))
              if not vim.endswith(parent, SEPARATOR) then
                parent = parent .. SEPARATOR
              end
              Actions.openDirectory(s, parent).run()
              return
            end

            local prefix = s.abbr_path or s.current_path
            if line:sub(1, #prefix) ~= prefix then
              return
            end
            local query = line:sub(#prefix + 1):gsub('^' .. vim.pesc(SEPARATOR), '')

            if query == '' then
              if s.searching then
                Actions.openDirectory(s, s.current_path).run()
              end
              return
            end

            if query:sub(-1) == SEPARATOR then
              local full_path = vim.fs.joinpath(s.current_path, query)
              if PathOps.isDirectory(full_path) then
                Actions.openDirectory(s, full_path).run()
              end
              return
            end

            s.search_engine.search(s, query, function(entries, count)
              if not windows_valid() then
                return
              end
              local name_width = 0
              for _, e in ipairs(entries) do
                name_width = math.max(name_width, api.nvim_strwidth(display_name(e)))
              end
              s.searching = true
              s.maxwidth = name_width
              update_display(s, entries, nil, count)
            end, 50)
          end

          api.nvim_buf_attach(s.search_buf, false, {
            on_lines = function()
              if s.closed then
                return true -- detach
              end
              if s.setting_prompt or api.nvim_get_current_buf() ~= s.search_buf then
                return
              end
              vim.schedule(on_prompt_changed)
            end,
            on_detach = function()
              if s.search_engine then
                s.search_engine.destroy()
              end
            end,
          })

          return F.IO.of(s)
        end)
      end)
    end)
  end,
}

Browser.refresh = function(state, path)
  return F.IO.fromEffect(function()
    local handle = uv.fs_scandir(path)
    if not handle then
      Notify.err('Failed to read directory: ' .. path)
      state.applying = false
      if api.nvim_buf_is_valid(state.buf) then
        vim.bo[state.buf].modifiable = true
      end
    end

    local names = {}
    while true do
      local name = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if state.show_hidden or not name:match('^%.') then
        table.insert(names, name)
      end
    end

    state.refresh_id = (state.refresh_id or 0) + 1
    local my_id = state.refresh_id

    state.current_path = path
    state.abbr_path = nil
    local home = vim.env.HOME and vim.fs.normalize(vim.env.HOME)
    if home and home ~= '' then
      home = home:gsub('/$', '')
      if path:sub(1, #home + 1) == home .. '/' then
        state.abbr_path = '~' .. path:sub(#home + 1)
      end
    end
    state.searching = false
    state.search_engine.reset()
    state.loading = true
    state.entries = {}

    local function finish(collected)
      if my_id ~= state.refresh_id then
        return
      end
      table.sort(collected, function(a, b)
        return a.name < b.name
      end)
      local width = 0
      for _, e in ipairs(collected) do
        width = math.max(width, api.nvim_strwidth(display_name(e)))
      end
      state.maxwidth = width
      state.entries = collected
      state.loading = false
      state.update_display(state, collected)
    end

    if #names == 0 then
      finish({})
      return state
    end

    local pending = #names
    local collected = {}
    for _, name in ipairs(names) do
      local full = vim.fs.joinpath(path, name)
      uv.fs_stat(full, function(err, stat)
        if err or not stat then
          stat = uv.fs_lstat(full)
        end
        if stat then
          table.insert(collected, { name = name, stat = stat })
        end
        pending = pending - 1
        if pending == 0 then
          vim.schedule(function()
            finish(collected)
          end)
        end
      end)
    end

    return state
  end)
end

Actions.createAndEdit = function(state, path, action)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      local dir_path = vim.fs.dirname(path)
      if vim.fn.isdirectory(dir_path) == 0 and vim.fn.mkdir(dir_path, 'p') == 0 then
        reject('Failed to create directory: ' .. dir_path)
        return
      end

      local function open()
        vim.schedule(function()
          Actions.close(state)
          action(path)
          resolve(state)
        end)
      end
      FileOps.createFile(path).fork(function(err)
        if tostring(err):match('EEXIST') then
          return open()
        end
        reject(err)
      end, open)
    end,
  }
end

Actions.setPrompt = function(state)
  if not api.nvim_buf_is_valid(state.search_buf) then
    return
  end
  local path = state.abbr_path or state.current_path
  state.last_line = path
  state.setting_prompt = true
  local ok, err = pcall(api.nvim_buf_set_lines, state.search_buf, 0, -1, false, { path })
  state.setting_prompt = false
  if not ok then
    Notify.err(err)
    return
  end
  local end_col = #path
  if api.nvim_win_is_valid(state.search_win) then
    api.nvim_win_set_cursor(state.search_win, { 1, end_col })
  end
  state.prompt_mark = api.nvim_buf_set_extmark(state.search_buf, ns_id, 0, 0, {
    id = state.prompt_mark,
    end_col = end_col,
    hl_group = 'DiredPrompt',
  })
end

Actions.openDirectory = function(state, path)
  return F.IO.chain(Browser.refresh(state, path), function(refreshed_state)
    return F.IO.fromEffect(function()
      Actions.setPrompt(refreshed_state)
      if
        api.nvim_get_current_buf() == refreshed_state.search_buf
        and api.nvim_get_mode().mode ~= 'i'
      then
        vim.cmd('startinsert!')
      end
      return refreshed_state
    end)
  end)
end

Actions.close = function(state)
  if state.cleanup then
    state.cleanup()
  end
  vim.cmd.stopinsert()
  pcall(api.nvim_win_close, state.search_win, true)
  pcall(api.nvim_win_close, state.win, true)
  if state.origin_win and api.nvim_win_is_valid(state.origin_win) then
    api.nvim_set_current_win(state.origin_win)
  end
end

Actions.openFile = function(state, path, action)
  Actions.close(state)
  action(path)
end

Browser.setup = function(state)
  return F.IO.fromEffect(function()
    local keymaps = {
      {
        key = Config.keymaps.open,
        action = function()
          local current_buf = api.nvim_get_current_buf()
          if current_buf == state.buf and api.nvim_get_mode().mode == 'i' then
            return api.nvim_feedkeys(
              api.nvim_replace_termcodes('<CR>', true, false, true),
              'n',
              false
            )
          end
          local selected = PathOps.getSelectPath(state)
          if current_buf == state.search_buf and #state.entries == 0 then
            local new_path = api.nvim_buf_get_lines(state.search_buf, 0, 1, false)[1] or ''
            new_path = vim.fs.normalize(new_path)
            if
              new_path == ''
              or vim.endswith(new_path, SEPARATOR)
              or PathOps.isDirectory(new_path)
            then
              return
            end
            Actions.createAndEdit(state, new_path, vim.cmd.edit).fork(function(err)
              Notify.err(err)
            end, function() end)
          elseif PathOps.isDirectory(selected) then
            Actions.openDirectory(state, selected).run()
          elseif PathOps.isFile(selected) then
            Actions.openFile(state, selected, vim.cmd.edit)
          end
        end,
        buffer = { state.search_buf, state.buf },
      },
      {
        key = Config.keymaps.up,
        action = function()
          local current = state.current_path
          local parent = vim.fs.dirname(vim.fs.normalize(current))
          if not vim.endswith(parent, SEPARATOR) then
            parent = parent .. SEPARATOR
          end
          Actions.openDirectory(state, parent).run()
        end,
        buffer = { state.search_buf, state.buf },
      },
      {
        key = Config.keymaps.quit,
        action = function()
          Actions.close(state)
        end,
        buffer = { state.search_buf, state.buf },
      },
      {
        key = Config.keymaps.switch,
        action = function()
          vim.wo[state.win].eventignorewin = 'InsertLeave'
          if api.nvim_get_current_win() == state.search_win then
            api.nvim_set_current_win(state.win)
          else
            api.nvim_set_current_win(state.search_win)
          end
          vim.schedule(function()
            vim.wo[state.win].eventignorewin = ''
          end)
        end,
        buffer = { state.search_buf, state.buf },
      },
      {
        key = Config.keymaps.toggle_hidden,
        action = function()
          state.show_hidden = not state.show_hidden
          Notify.info(string.format('Hidden files %s', state.show_hidden and 'shown' or 'hidden'))
          Actions.openDirectory(state, state.current_path).run()
        end,
        buffer = { state.search_buf, state.buf },
      },
      {
        key = Config.keymaps.forward,
        action = function()
          local pos = api.nvim_win_get_cursor(state.win)
          local count = api.nvim_buf_line_count(state.buf)
          pos[1] = pos[1] + 1 > count and 1 or pos[1] + 1
          api.nvim_win_set_cursor(state.win, pos)
          api.nvim_exec_autocmds('CursorMoved', { buffer = state.buf, modeline = false })
        end,
      },
      {
        key = Config.keymaps.backward,
        action = function()
          local pos = api.nvim_win_get_cursor(state.win)
          local count = api.nvim_buf_line_count(state.buf)
          pos[1] = pos[1] - 1 == 0 and count or pos[1] - 1
          api.nvim_win_set_cursor(state.win, pos)
          api.nvim_exec_autocmds('CursorMoved', { buffer = state.buf, modeline = false })
        end,
      },
      {
        key = { i = SEPARATOR },
        action = function()
          local search_path = PathOps.getSearchPath(state)
          search_path = search_path and (search_path .. SEPARATOR)
          if search_path and PathOps.isDirectory(search_path) then
            Actions.openDirectory(state, search_path).run()
          else
            api.nvim_feedkeys(SEPARATOR, 'n', false)
          end
        end,
      },
      {
        key = Config.keymaps.split,
        action = function()
          local new_path = PathOps.getSelectPath(state)
          local search_path = PathOps.getSearchPath(state)

          if
            #state.entries == 0
            and search_path
            and not vim.endswith(search_path, SEPARATOR)
            and not PathOps.isDirectory(search_path)
            and not PathOps.isFile(search_path)
          then
            Actions.createAndEdit(state, search_path, vim.cmd.split).fork(function(err)
              Notify.err(err)
            end, function() end)
            return
          end

          if PathOps.isFile(new_path) then
            Actions.openFile(state, new_path, vim.cmd.split)
          end
        end,
        buffer = { state.search_buf, state.buf },
      },
      {
        key = Config.keymaps.vsplit,
        action = function()
          local new_path = PathOps.getSelectPath(state)
          local search_path = PathOps.getSearchPath(state)

          if
            #state.entries == 0
            and search_path
            and not vim.endswith(search_path, SEPARATOR)
            and not PathOps.isDirectory(search_path)
            and not PathOps.isFile(search_path)
          then
            Actions.createAndEdit(state, search_path, vim.cmd.vsplit).fork(function(err)
              Notify.err(err)
            end, function() end)
            return
          end

          if PathOps.isFile(new_path) then
            Actions.openFile(state, new_path, vim.cmd.vsplit)
          end
        end,
        buffer = { state.search_buf, state.buf },
      },
      {
        key = Config.keymaps.open_cur,
        action = function()
          local cb = vim.b[state.search_buf].curbuf
          local name = (cb and api.nvim_buf_is_valid(cb)) and api.nvim_buf_get_name(cb) or ''
          local curdir = name ~= '' and vim.fs.dirname(name) or vim.fn.getcwd()
          if not vim.endswith(curdir, SEPARATOR) then
            curdir = curdir .. SEPARATOR
          end
          Actions.openDirectory(state, curdir).run()
        end,
        buffer = { state.search_buf },
      },
    }

    local nmap = function(map)
      local key = map.key
      if type(map.key) ~= 'table' then
        key = {
          [map.mode or 'n'] = map.key,
        }
      end
      for m, k in pairs(key) do
        k = type(k) == 'string' and { k } or k
        for _, item in ipairs(k) do
          if map.buffer and type(map.buffer) == 'table' then
            for _, b in ipairs(map.buffer) do
              mapset(m, item, map.action, { buffer = b })
            end
          else
            mapset(m, item, map.action, { buffer = map.buffer or state.search_buf })
          end
        end
      end
    end

    for _, map in ipairs(keymaps) do
      nmap(map)
    end

    mapset('n', 'G', function()
      api.nvim_set_current_win(state.win)
      api.nvim_feedkeys(api.nvim_replace_termcodes('G', true, false, true), 'n', false)
    end, { buffer = state.search_buf })
    return state
  end)
end

Browser.rowEntries = function(state)
  local rows = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(state.buf, ns_entry, 0, -1, { details = true })) do
    local id, row, col, details = m[1], m[2], m[3], m[4] or {}
    local entry = state.mark_entry[id]
    if entry and not details.invalid then
      local cur = rows[row]
      if not cur or col < cur.col then
        rows[row] = { col = col, entry = entry }
      end
    end
  end
  return rows
end

Browser.entriesInRange = function(state, a, b)
  if state.loading then
  end
  local rows = Browser.rowEntries(state)
  local list = {}
  for l = math.min(a, b), math.max(a, b) do
    if rows[l - 1] then
      table.insert(list, rows[l - 1].entry)
    end
  end
  return list
end

local function strip_sep(name)
  return (name:gsub('/+$', ''))
end

local function is_absolute(name)
  return vim.startswith(name, '/') or vim.startswith(name, '~') or name:match('^%a:[/\\]') ~= nil
end

local function resolve_target(base, name)
  if is_absolute(name) then
    return vim.fs.normalize(name)
  end
  return vim.fs.normalize(vim.fs.joinpath(base, name))
end

local function same_file(a, b)
  local sa, sb = uv.fs_lstat(a), uv.fs_lstat(b)
  return sa and sb and sa.ino == sb.ino and sa.dev == sb.dev
end

Browser.planChanges = function(state)
  local path = state.current_path
  local lines = api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local rows = Browser.rowEntries(state)
  local kept, renames, unmarked = {}, {}, {}

  for i, line in ipairs(lines) do
    local text = vim.trim(line)
    local r = rows[i - 1]
    if r then
      local entry = r.entry
      if text ~= '' and not kept[entry] then
        kept[entry] = true
        local new = strip_sep(text)
        if new ~= entry.name then
          table.insert(renames, { entry = entry, new = new })
        end
      end
    elseif text ~= '' then
      table.insert(unmarked, text)
    end
  end

  local orphans = {}
  for _, entry in pairs(state.mark_entry) do
    if not kept[entry] then
      orphans[entry.name] = entry
    end
  end

  local creates, notes = {}, {}
  local seen_create = {}
  for _, text in ipairs(unmarked) do
    local name = strip_sep(text)
    if orphans[name] then
      kept[orphans[name]] = true
      orphans[name] = nil
    elseif seen_create[text] then
      table.insert(notes, 'duplicate line ignored: ' .. text)
    else
      seen_create[text] = true
      table.insert(creates, { name = name, is_directory = vim.endswith(text, '/') })
    end
  end

  local deletes = {}
  for _, entry in pairs(orphans) do
    table.insert(deletes, entry)
  end
  table.sort(deletes, function(a, b)
    return a.name < b.name
  end)

  local errors = {}
  local freed = {}
  for _, e in ipairs(deletes) do
    freed[vim.fs.joinpath(path, e.name)] = true
  end
  for _, r in ipairs(renames) do
    freed[vim.fs.joinpath(path, r.entry.name)] = true
  end
  local targets = {}
  local need_two_phase = false
  for _, r in ipairs(renames) do
    r.old_path = vim.fs.joinpath(path, r.entry.name)
    r.new_path = resolve_target(path, r.new)
    if targets[r.new_path] then
      table.insert(errors, 'two items renamed to ' .. r.new)
    end
    targets[r.new_path] = true
    if uv.fs_lstat(r.new_path) and not same_file(r.old_path, r.new_path) then
      if freed[r.new_path] then
        need_two_phase = true
      else
        table.insert(errors, 'target already exists: ' .. r.new)
      end
    end
  end
  for _, c in ipairs(creates) do
    c.path = resolve_target(path, c.name)
    if targets[c.path] then
      table.insert(errors, 'created name collides with a rename: ' .. c.name)
    end
    targets[c.path] = true
    if uv.fs_lstat(c.path) and not freed[c.path] then
      table.insert(errors, 'already exists: ' .. c.name)
    end
  end

  return {
    deletes = deletes,
    renames = renames,
    creates = creates,
    errors = errors,
    notes = notes,
    two_phase = need_two_phase,
  }
end

Browser.applyChanges = function(state)
  if state.closed or not api.nvim_buf_is_valid(state.buf) then
    return
  end
  if state.loading or state.applying then
    return
  end
  local tick = api.nvim_buf_get_changedtick(state.buf)
  if tick == state.render_tick or tick == state.handled_tick then
    return
  end
  state.handled_tick = tick

  local plan = Browser.planChanges(state)
  for _, n in ipairs(plan.notes) do
    Notify.info(n)
  end
  if #plan.errors > 0 then
    Notify.err('Changes not applied:\n' .. table.concat(plan.errors, '\n'))
    Browser.refresh(state, state.current_path).run()
    return
  end
  if #plan.deletes + #plan.renames + #plan.creates == 0 then
    return
  end

  if Config.confirm_delete and #plan.deletes > 0 then
    local summary = {}
    local function add(prefix, text)
      if #summary < 15 then
        table.insert(summary, prefix .. text)
      end
    end
    for _, e in ipairs(plan.deletes) do
      add(Config.use_trash and '  trash   ' or '  DELETE  ', display_name(e))
    end
    for _, r in ipairs(plan.renames) do
      add('  rename  ', r.entry.name .. ' -> ' .. r.new)
    end
    for _, c in ipairs(plan.creates) do
      add('  create  ', c.name .. (c.is_directory and '/' or ''))
    end
    local total = #plan.deletes + #plan.renames + #plan.creates
    if total > #summary then
      table.insert(summary, ('  ... %d more'):format(total - #summary))
    end
    local choice = vim.fn.confirm(
      ('Apply changes in %s?\n%s'):format(state.current_path, table.concat(summary, '\n')),
      '&Yes\n&No',
      2
    )
    if choice ~= 1 then
      Notify.info('Cancelled')
      return
    end
  end

  local operations = {}
  for _, e in ipairs(plan.deletes) do
    table.insert(operations, {
      type = 'delete',
      path = vim.fs.joinpath(state.current_path, e.name),
      is_directory = e.stat.type == 'directory',
      name = e.name,
    })
  end
  if plan.two_phase then
    local stamp = tostring(uv.hrtime())
    for i, r in ipairs(plan.renames) do
      r.tmp_path =
        vim.fs.joinpath(vim.fs.dirname(r.old_path), ('.dired_tmp_%s_%d'):format(stamp, i))
      table.insert(
        operations,
        { type = 'rename', old_path = r.old_path, new_path = r.tmp_path, name = r.entry.name }
      )
    end
    for _, r in ipairs(plan.renames) do
      table.insert(
        operations,
        { type = 'rename', old_path = r.tmp_path, new_path = r.new_path, name = r.new }
      )
    end
  else
    for _, r in ipairs(plan.renames) do
      table.insert(
        operations,
        { type = 'rename', old_path = r.old_path, new_path = r.new_path, name = r.new }
      )
    end
  end
  table.sort(plan.creates, function(a, b)
    return select(2, a.name:gsub('/', '')) < select(2, b.name:gsub('/', ''))
  end)
  for _, c in ipairs(plan.creates) do
    table.insert(
      operations,
      { type = 'create', path = c.path, is_directory = c.is_directory, name = c.name }
    )
  end

  local focus = plan.creates[1] and plan.creates[1].name
    or (plan.renames[1] and plan.renames[1].new)
  if focus then
    state.target_op = { name = focus:match('^[^/]+') }
  end
  Browser.executeOperations(state, operations)
end

Browser.executeOperations = function(state, operations)
  operations = vim.tbl_filter(function(op)
    return op.path ~= nil or op.old_path ~= nil
  end, operations)
  if #operations == 0 then
    return
  end
  local total = #operations
  local errors = {}

  state.applying = true
  if api.nvim_buf_is_valid(state.buf) then
    vim.bo[state.buf].modifiable = false
  end
  if api.nvim_win_is_valid(state.win) then
    state.before_pos = api.nvim_win_get_cursor(state.win)
  end

  local function updateStatus()
    if #errors > 0 then
      Notify.err(
        string.format('Completed with %d errors:\n%s', #errors, table.concat(errors, '\n'))
      )
    else
      Notify.info(string.format('Successfully applied %d changes', total))
    end
    if state.closed then
      return
    end
    Actions.openDirectory(state, state.current_path).run()
  end

  local executeNextOperation

  local function next_step(index)
    vim.schedule(function()
      executeNextOperation(index)
    end)
  end

  local function ensure_parent(p)
    local dir = vim.fs.dirname(p)
    if vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, 'p')
    end
  end

  executeNextOperation = function(index)
    if index > #operations then
      updateStatus()
      return
    end

    local op = operations[index]
    local function ok_cb()
      next_step(index + 1)
    end
    local function fail(msg)
      table.insert(errors, msg)
      next_step(index + 1)
    end

    if op.type == 'delete' then
      local task
      if Config.use_trash then
        task = FileOps.moveToTrash(op.path)
      else
        task = op.is_directory and FileOps.deleteDirectory(op.path) or FileOps.deleteFile(op.path)
      end
      task.fork(function(err)
        local action = Config.use_trash and 'move to trash' or 'delete'
        fail(string.format('Failed to %s %s: %s', action, op.name, err))
      end, ok_cb)
    elseif op.type == 'create' then
      ensure_parent(op.path)
      if op.is_directory then
        FileOps.createDirectory(op.path).fork(function(err)
          if tostring(err):match('EEXIST') then
            return ok_cb()
          end
          fail('Failed to create directory ' .. op.name .. ': ' .. err)
        end, ok_cb)
      else
        FileOps.createFile(op.path).fork(function(err)
          fail('Failed to create file ' .. op.name .. ': ' .. err)
        end, ok_cb)
      end
    elseif op.type == 'rename' then
      ensure_parent(op.new_path)
      FileOps.moveAcross(op.old_path, op.new_path).fork(function(err)
        fail('Failed to rename ' .. op.name .. ': ' .. err)
      end, ok_cb)
    else
      next_step(index + 1)
    end
  end

  executeNextOperation(1)
end

local function browse_directory(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  path = vim.endswith(path, SEPARATOR) and path or path .. SEPARATOR

  local result = F.IO
    .chain(Browser.State.create(path), function(state)
      return F.IO.chain(Browser.setup(state), function(s)
        return Actions.openDirectory(s, path)
      end)
    end)
    .run()
  if result.tag == 'Left' then
    Notify.err('dired: ' .. tostring(result.value))
  end
end

return { browse_directory = browse_directory }
