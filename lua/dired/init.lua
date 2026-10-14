local api, uv, ffi = vim.api, vim.uv, require('ffi')
local bit = require('bit')
local mapset = vim.keymap.set
local ops = require('dired.ops')
local FileOps, PathOps = ops.FileOps, ops.PathOps
local ns_id = api.nvim_create_namespace('dired_highlights')
local ns_mark = api.nvim_create_namespace('dired_marks')
local ns_entry = api.nvim_create_namespace('dired_entries')
local ns_meta = api.nvim_create_namespace('dired_meta')
local SEPARATOR = '/'
local IS_WIN = vim.fn.has('win32') == 1

-- FFI definitions. pcall: re-sourcing this module, or another plugin declaring
-- the same names, makes ffi.cdef raise "attempt to redefine".
pcall(ffi.cdef, 'typedef unsigned int uv_uid_t;')
pcall(ffi.cdef, 'int os_get_uname(uv_uid_t uid, char *s, size_t len);')

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

-- Resolved once per browse_directory() call. The previous metatable re-read
-- vim.g.dired (a full Vimscript -> Lua conversion) on every field access,
-- including once per rendered entry and inside table.sort comparators.
local function resolve_config()
  local user = vim.g.dired or {}
  local cfg = {}
  for k, v in pairs(DEFAULTS) do
    cfg[k] = v
  end
  for k, v in pairs(user) do
    if k ~= 'keymaps' then
      cfg[k] = v
    end
  end
  local km = vim.tbl_extend('force', DEFAULTS.keymaps, user.keymaps or {})
  if user.keymaps and user.keymaps.toogle_hidden and not user.keymaps.toggle_hidden then
    km.toggle_hidden = user.keymaps.toogle_hidden
  end
  cfg.keymaps = km
  return cfg
end

---@type DiredConfig
local Config = resolve_config()

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

-- Run an IO and surface a Left. Bare `.run()` dropped the Either, so any error
-- raised inside refresh/openDirectory vanished without a trace.
local function run_io(io)
  local result = io.run()
  if result.tag == 'Left' then
    Notify.err('dired: ' .. tostring(result.value))
  end
  return result
end

-- Pure formatting utilities
local Format = {}

local PERM = { [0] = '---', '--x', '-w-', '-wx', 'r--', 'r-x', 'rw-', 'rwx' }
Format.permissions = function(mode)
  return PERM[bit.band(bit.rshift(mode, 6), 7)]
    .. PERM[bit.band(bit.rshift(mode, 3), 7)]
    .. PERM[bit.band(mode, 7)]
end

local username_cache = {}
local uname_buf
Format.username = function(user_id)
  local cached = username_cache[user_id]
  if cached then
    return cached
  end
  local ok, name = pcall(function()
    uname_buf = uname_buf or ffi.new('char[256]')
    if ffi.C.os_get_uname(user_id, uname_buf, 256) == 0 then
      return nil
    end
    return ffi.string(uname_buf)
  end)
  name = (ok and name and name ~= '') and name or tostring(user_id)
  username_cache[user_id] = name
  return name
end

local SIZE_UNITS = { { 1073741824, 'G' }, { 1048576, 'M' }, { 1024, 'K' } }
Format.size = function(size)
  for i = 1, #SIZE_UNITS do
    local u = SIZE_UNITS[i]
    if size >= u[1] then
      return ('%.2f%s'):format(size / u[1], u[2])
    end
  end
  return ('%.2fB'):format(size)
end

Format.friendly_time = function(timestamp, now)
  local diff = (now or os.time()) - timestamp
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

-- UI Components
local UI = {}
-- Browser implementation
local Browser = {}
local Actions = {}
-- buf -> state, read by the decoration provider
local active = {}

-- Text shown for an entry, cached on the entry. Newlines are legal in file names
-- but nvim_buf_set_lines rejects them, so they are escaped for display only;
-- operations always use entry.name.
local function display_name(entry)
  local d = entry.display
  if not d then
    d = entry.name .. (entry.stat.type == 'directory' and SEPARATOR or '')
    if d:find('\n', 1, true) then
      d = d:gsub('\n', '\\n')
    end
    entry.display = d
  end
  return d
end

local function text_width(s)
  if s:find('[\128-\255]') then
    return api.nvim_strwidth(s)
  end
  return #s
end

local function strip_sep(name)
  return (name:gsub('/+$', ''))
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
  -- Only the identity mark and match highlights are real extmarks. The metadata
  -- column is drawn on demand for visible rows by the decoration provider, so
  -- rendering a 50k-entry directory no longer formats 50k rows up front.
  render = function(state, row, entry)
    local id = api.nvim_buf_set_extmark(state.buf, ns_entry, row, 0, {
      invalidate = true,
      right_gravity = true,
    })
    state.mark_entry[id] = entry

    if entry.match_pos then
      for _, span in ipairs(entry.match_pos) do
        api.nvim_buf_set_extmark(state.buf, ns_id, row, span[1], {
          end_col = span[2],
          hl_group = 'DiredMatch',
          hl_mode = 'combine',
        })
      end
    end
  end,
  meta = function(entry, now)
    local st = entry.stat
    local m = entry.meta
    if not m then
      m = {
        perms = ('%-11s '):format(entry.perms or Format.permissions(st.mode)),
        size = ('%-10s '):format(entry.size or Format.size(st.size)),
      }
      entry.meta = m
    end
    local chunks = { { m.perms, 'DiredPermissions' } }
    if Config.show_user then
      m.user = m.user or ('%-10s '):format(entry.user or Format.username(st.uid))
      chunks[#chunks + 1] = { m.user, 'DiredUser' }
    end
    chunks[#chunks + 1] = { m.size, 'DiredSize' }
    chunks[#chunks + 1] = {
      ('%-20s '):format(entry.date or Format.friendly_time(st.mtime.sec, now)),
      'DiredDate',
    }
    return chunks
  end,
}

-- Entry for a 0-based row. While the buffer is untouched since the last render
-- rows map 1:1 onto state.shown; after edits fall back to the identity extmarks.
local function entry_on_row(state, row, fast)
  if fast == nil then
    fast = api.nvim_buf_get_changedtick(state.buf) == state.render_tick
  end
  if fast then
    return state.shown[row + 1]
  end
  local best, best_col
  for _, m in
    ipairs(api.nvim_buf_get_extmarks(state.buf, ns_entry, { row, 0 }, { row, -1 }, {
      details = true,
    }))
  do
    local e = state.mark_entry[m[1]]
    if e and not (m[4] and m[4].invalid) and (not best_col or m[3] < best_col) then
      best, best_col = e, m[3]
    end
  end
  return best
end

api.nvim_set_decoration_provider(ns_meta, {
  on_win = function(_, _, buf)
    local s = active[buf]
    if not s or s.closed then
      return false
    end
    s.draw_now = os.time()
    s.draw_fast = api.nvim_buf_get_changedtick(buf) == s.render_tick
    return true
  end,
  on_line = function(_, _, buf, row)
    local s = active[buf]
    if not s then
      return
    end
    local ok, entry = pcall(entry_on_row, s, row, s.draw_fast)
    if not ok or not entry then
      return
    end
    local ok2, chunks = pcall(UI.Entry.meta, entry, s.draw_now)
    if not ok2 then
      return
    end
    pcall(api.nvim_buf_set_extmark, buf, ns_meta, row, 0, {
      ephemeral = true,
      virt_text = chunks,
      virt_text_win_col = (s.maxwidth or 0) + 6,
      hl_mode = 'combine',
    })
  end,
})

UI.setTitle = function(state, cur, total)
  if not api.nvim_buf_is_valid(state.search_buf) then
    return
  end
  state.count_mark = api.nvim_buf_set_extmark(state.search_buf, ns_id, 0, 0, {
    id = state.count_mark,
    virt_text = { { ('[%d/%d]   Find File: '):format(cur, total), 'DiredTitle' } },
    virt_text_pos = 'inline',
  })
end

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
      -- Per-instance group: a shared name let a second instance wipe the first
      -- instance's autocmds (including its WinClosed cleanup).
      state.group = api.nvim_create_augroup('DiredGroup' .. state.buf, { clear = true })
      active[state.buf] = state

      local function cleanup()
        if state.closed then
          return
        end
        state.closed = true
        active[state.buf] = nil
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

      local function on_cursor_moved()
        if not api.nvim_buf_is_valid(state.search_buf) or not api.nvim_win_is_valid(state.win) then
          return
        end
        local row = api.nvim_win_get_cursor(state.win)[1]
        UI.setTitle(state, row, state.total_count or #(state.shown or {}))
        if state.shortcut_manager then
          state.shortcut_manager.sync()
        end
      end
      state.on_cursor_moved = on_cursor_moved

      api.nvim_create_autocmd('CursorMoved', {
        group = state.group,
        buffer = state.buf,
        callback = on_cursor_moved,
      })
      api.nvim_create_autocmd('WinScrolled', {
        group = state.group,
        pattern = tostring(state.win),
        callback = function()
          if state.shortcut_manager then
            state.shortcut_manager.sync()
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

local function is_inside(child, parent)
  parent = strip_sep(parent)
  return child:sub(1, #parent + 1) == parent .. '/'
end

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

    do
      local lst = uv.fs_lstat(full_source_path)
      if lst and lst.type == 'directory' and is_inside(target_path, full_source_path) then
        Notify.err('cannot paste a directory into itself: ' .. source_name)
        goto continue
      end
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
  local errors = {}

  local function updateStatus()
    if #errors > 0 then
      Notify.err(
        string.format('Paste finished with %d errors:\n%s', #errors, table.concat(errors, '\n'))
      )
    else
      local action = state.clipboard.type == 'copy' and 'copied' or 'moved'
      Notify.info(string.format('Successfully %s %d item(s)', action, total))
    end

    if state.clipboard.type == 'cut' then
      state.clipboard = {}
    end

    if state.closed then
      return
    end
    state.target_op = { name = vim.fs.basename(operations[1].target) }
    -- openDirectory rather than a bare refresh, so a search query left in the
    -- prompt does not disagree with the directory listing shown below it.
    run_io(Actions.openDirectory(state, state.current_path))
  end

  local function executeNextOperation(index)
    if index > #operations then
      updateStatus()
      return
    end

    local op = operations[index]
    local task = op.type == 'copy' and FileOps.copy(op.source, op.target)
      or FileOps.moveAcross(op.source, op.target)
    local verb = op.type == 'copy' and 'copy' or 'move'
    -- Items are independent and both operations refuse to overwrite, so keep
    -- going after a failure.
    task.fork(function(err)
      table.insert(errors, string.format('%s failed: %s: %s', verb, op.name, err))
      vim.schedule(function()
        executeNextOperation(index + 1)
      end)
    end, function()
      vim.schedule(function()
        executeNextOperation(index + 1)
      end)
    end)
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

-- Every shortcut key is mapped once, for the lifetime of the window. Keys are
-- tied to rows through extmarks, so a label follows its line through edits, and
-- scrolling only moves extmarks instead of deleting and re-creating keymaps.
local function create_shortcut_manager(state)
  local keys = shortcut_pool()
  local mark_of = {} -- key -> extmark id in ns_mark
  local prefix = {} -- first chars of configured multi-key normal maps (e.g. 'sv')
  for _, spec in pairs(Config.keymaps) do
    local n = type(spec) == 'table' and spec.n or (type(spec) == 'string' and spec or nil)
    for _, k in ipairs(type(n) == 'table' and n or { n }) do
      if type(k) == 'string' and #k > 1 and k:sub(1, 1) ~= '<' then
        prefix[k:sub(1, 1)] = true
      end
    end
  end

  local function key_row(key)
    local id = mark_of[key]
    if not id then
      return nil
    end
    local pos = api.nvim_buf_get_extmark_by_id(state.buf, ns_mark, id, { details = true })
    if not pos[1] or (pos[3] and pos[3].invalid) then
      return nil
    end
    return pos[1]
  end

  local function press(key)
    if not api.nvim_buf_is_valid(state.buf) then
      return
    end
    local row = key_row(key)
    if not row then
      -- No label on screen for this key: behave like the unmapped key.
      local count = vim.v.count > 0 and tostring(vim.v.count) or ''
      api.nvim_feedkeys(count .. key, 'n', false)
      return
    end
    Browser.openRow(state, row + 1)
  end

  for _, key in ipairs(keys) do
    -- nowait: without it a global `ds`/`cs`/`ys` (nvim-surround) or `s` prefix
    -- (leap/flash) makes the buffer-local key wait 'timeoutlen'.
    mapset('n', key, function()
      press(key)
    end, { buffer = state.search_buf, nowait = not prefix[key], desc = 'dired: jump to entry' })
  end

  local function place(key, row)
    mark_of[key] = api.nvim_buf_set_extmark(state.buf, ns_mark, row, 0, {
      id = mark_of[key],
      virt_text_pos = 'inline',
      virt_text = { { ('[%s] '):format(key), 'DiredShort' } },
      invalidate = true,
      right_gravity = false,
    })
  end

  local function drop(key)
    local id = mark_of[key]
    if id then
      pcall(api.nvim_buf_del_extmark, state.buf, ns_mark, id)
      mark_of[key] = nil
    end
  end

  return {
    reset = function()
      mark_of = {}
      if api.nvim_buf_is_valid(state.buf) then
        api.nvim_buf_clear_namespace(state.buf, ns_mark, 0, -1)
      end
    end,
    -- Label exactly the visible rows; rows that already have a key keep it.
    sync = function()
      if not api.nvim_buf_is_valid(state.buf) or not api.nvim_win_is_valid(state.win) then
        return
      end
      local range = api.nvim_win_call(state.win, function()
        return { vim.fn.line('w0'), vim.fn.line('w$') }
      end)
      local top = range[1]
      local bot = math.min(range[2], api.nvim_buf_line_count(state.buf))
      if #state.shown == 0 then
        bot = top - 1
      end

      local taken, free = {}, {}
      for _, key in ipairs(keys) do
        local row = key_row(key)
        if row and row + 1 >= top and row + 1 <= bot and not taken[row] then
          taken[row] = key
        else
          free[#free + 1] = key
        end
      end

      local fi = 1
      for lnum = top, bot do
        if not taken[lnum - 1] then
          local key = free[fi]
          if not key then
            break
          end
          fi = fi + 1
          place(key, lnum - 1)
        end
      end
      for i = fi, #free do
        drop(free[i])
      end
    end,
  }
end

local MAX_RESULTS = 80

local fd_bin -- nil: not probed yet, false: unavailable
local function find_fd()
  if fd_bin == nil then
    fd_bin = (vim.fn.executable('fd') == 1 and 'fd')
      or (vim.fn.executable('fdfind') == 1 and 'fdfind')
      or false
  end
  return fd_bin or nil
end

local function create_debounced_search()
  local timer = nil
  local job = nil
  local gen = 0
  local inflight = false -- a search() call has not delivered its result yet
  local cache = nil -- { path, hidden, names, waiters }
  local narrow = nil -- { names, query, matched }: previous result for refinement

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

  local function walk_lua(path, show_hidden)
    local names = {}
    local max = Config.search_max_files
    pcall(function()
      for name, _ in
        vim.fs.dir(path, {
          depth = Config.search_depth,
          skip = function(dir)
            local base = vim.fs.basename(dir)
            if base == '.git' or base == 'node_modules' then
              return false
            end
            return show_hidden or base:byte(1) ~= 46
          end,
        })
      do
        if show_hidden or name:match('[^/]*$'):byte(1) ~= 46 then
          names[#names + 1] = name
          if #names >= max then
            break
          end
        end
      end
    end)
    return names
  end

  local function list_files(path, show_hidden, cb)
    if cache and cache.path == path and cache.hidden == show_hidden then
      if cache.names then
        return cb(cache.names)
      end
      table.insert(cache.waiters, cb)
      return
    end
    kill_job()
    local my = { path = path, hidden = show_hidden, waiters = { cb } }
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
        done(walk_lua(path, show_hidden))
      end)
      return
    end

    local cmd = { fd }
    if show_hidden then
      cmd[#cmd + 1] = '--hidden'
    end
    vim.list_extend(cmd, {
      '--exclude',
      '.git',
      '--max-depth',
      tostring(Config.search_depth),
      '--max-results',
      tostring(Config.search_max_files),
      '--color',
      'never',
      '--print0',
    })

    local ok, obj = pcall(vim.system, cmd, { cwd = path, text = true }, function(res)
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
            names[#names + 1] = name
          end
        end
        done(names)
      end)
    end)
    if ok then
      job = obj
    else
      vim.schedule(function()
        done(walk_lua(path, show_hidden))
      end)
    end
  end

  local function run(state, query, callback, my_gen)
    local path = state.current_path
    list_files(path, state.show_hidden, function(names)
      if my_gen ~= gen or state.closed or state.current_path ~= path then
        return
      end
      -- Fuzzy matches of `abc` are a superset of matches of `abcd`, so while the
      -- user keeps typing only the previous hits need re-scoring.
      local pool = names
      if
        narrow
        and narrow.names == names
        and narrow.query:find('%S')
        and query:sub(1, #narrow.query) == narrow.query
      then
        pool = narrow.matched
      end
      -- matchfuzzy (no positions) for the full ranked list and count; positions
      -- are computed only for the rows that will actually be displayed.
      local matched = #pool > 0 and vim.fn.matchfuzzy(pool, query) or {}
      narrow = { names = names, query = query, matched = matched }

      local top = {}
      for i = 1, math.min(#matched, MAX_RESULTS) do
        top[i] = matched[i]
      end
      local res = #top > 0 and vim.fn.matchfuzzypos(top, query) or { {}, {} }
      local shown, positions = res[1], res[2]

      local results = {}
      for i, name in ipairs(shown) do
        local full = path .. name
        local stat = uv.fs_stat(full) or uv.fs_lstat(full)
        if stat then
          local spans = {}
          local ascii = not name:find('[\128-\255]')
          for _, ci in ipairs(positions[i]) do
            if ascii then
              spans[#spans + 1] = { ci, ci + 1 }
            else
              spans[#spans + 1] = { vim.fn.byteidx(name, ci), vim.fn.byteidx(name, ci + 1) }
            end
          end
          results[#results + 1] = { name = name, stat = stat, match_pos = spans }
        end
      end
      inflight = false
      callback(results, #matched)
    end)
  end

  return {
    search = function(state, query, callback, delay)
      stop_timer()
      gen = gen + 1
      inflight = true
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
    busy = function()
      return inflight
    end,
    -- drop pending work but keep the file list (query cleared, same directory)
    cancel = function()
      gen = gen + 1
      inflight = false
      stop_timer()
    end,
    reset = function()
      gen = gen + 1
      inflight = false
      stop_timer()
      kill_job()
      cache = nil
      narrow = nil
    end,
    destroy = function()
      gen = gen + 1
      inflight = false
      stop_timer()
      kill_job()
      cache = nil
      narrow = nil
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
          s.shown = {} -- entries currently rendered in the buffer
          s.show_hidden = Config.show_hidden
          s.clipboard = {}
          s.shortcut_manager = create_shortcut_manager(s)
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

          -- Synchronous: every caller already runs on the main loop, and the old
          -- extra vim.schedule only added a tick of latency per keystroke.
          local function update_display(_, entries_to_show, change_mode, total)
            if not windows_valid() then
              return
            end
            local buf = s.buf

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
            s.shortcut_manager.reset()
            s.mark_entry = {}
            for i, entry in ipairs(entries_to_show) do
              UI.Entry.render(s, i - 1, entry)
            end
            vim.bo[buf].modified = false
            vim.bo[buf].modifiable = not s.applying
            s.render_tick = api.nvim_buf_get_changedtick(buf)
            s.shown = entries_to_show
            s.total_count = total or #entries_to_show

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

            -- label what is on screen (the cursor may have been restored far down)
            s.shortcut_manager.sync()
            UI.setTitle(s, #entries_to_show > 0 and lnum or 0, s.total_count)

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

            local after = s.after_render
            s.after_render = nil
            if after then
              after()
            end
          end
          s.update_display = update_display

          -- Back to the plain listing without touching the disk.
          local function show_listing()
            s.searching = false
            s.query_shown = nil
            s.query_pending = nil
            s.search_engine.cancel()
            s.maxwidth = s.entries_width or 0
            update_display(s, s.entries, false)
          end

          local function on_prompt_changed()
            if not windows_valid() then
              return
            end
            local line = api.nvim_buf_get_lines(s.search_buf, 0, 1, false)[1] or ''
            if line == s.last_line and not s.searching and not s.search_engine.busy() then
              return
            end

            if s.last_line and line .. SEPARATOR == s.last_line then
              local parent = vim.fs.dirname(vim.fs.normalize(s.last_line))
              if not vim.endswith(parent, SEPARATOR) then
                parent = parent .. SEPARATOR
              end
              run_io(Actions.openDirectory(s, parent))
              return
            end

            local prefix = s.abbr_path or s.current_path
            if line:sub(1, #prefix) ~= prefix then
              return
            end
            local query = line:sub(#prefix + 1):gsub('^' .. vim.pesc(SEPARATOR), '')

            if query == '' then
              if s.searching then
                show_listing()
              else
                s.search_engine.cancel() -- else a late result for the old query lands
                s.query_pending = nil
              end
              return
            end

            if query:sub(-1) == SEPARATOR then
              local full_path = vim.fs.joinpath(s.current_path, query)
              if PathOps.isDirectory(full_path) then
                run_io(Actions.openDirectory(s, full_path))
              end
              return
            end

            if s.search_engine.busy() then
              if query == s.query_pending then
                return
              end
            elseif query == s.query_shown then
              return
            end

            s.query_pending = query
            s.search_engine.search(s, query, function(entries, count)
              if not windows_valid() then
                return
              end
              local name_width = 0
              for _, e in ipairs(entries) do
                name_width = math.max(name_width, text_width(display_name(e)))
              end
              s.searching = true
              s.maxwidth = name_width
              s.query_shown = query
              -- false: never push the user out of insert mode while typing
              update_display(s, entries, false, count)
            end, 50)
          end
          s.on_prompt_changed = on_prompt_changed

          api.nvim_buf_attach(s.search_buf, false, {
            on_lines = function()
              if s.closed then
                return true -- detach
              end
              if s.setting_prompt or api.nvim_get_current_buf() ~= s.search_buf then
                return
              end
              if not s.prompt_scheduled then
                s.prompt_scheduled = true
                vim.schedule(function()
                  s.prompt_scheduled = false
                  on_prompt_changed()
                end)
              end
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
    path = vim.fs.normalize(path)
    if not vim.endswith(path, SEPARATOR) then
      path = path .. SEPARATOR
    end
    local handle, scan_err = uv.fs_scandir(path)
    if not handle then
      Notify.err(('Failed to read directory: %s (%s)'):format(path, tostring(scan_err)))
      state.applying = false
      if api.nvim_buf_is_valid(state.buf) then
        vim.bo[state.buf].modifiable = true
      end
      return state -- was missing: execution fell through to scandir_next(nil)
    end

    local names = {}
    local show_hidden = state.show_hidden
    while true do
      local name = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if show_hidden or name:byte(1) ~= 46 then
        names[#names + 1] = name
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
    state.query_shown = nil
    state.query_pending = nil
    state.after_render = nil -- navigating cancels a deferred open
    state.search_engine.reset()
    state.loading = true
    state.entries = {}

    local function finish(collected)
      if my_id ~= state.refresh_id or state.closed then
        return
      end
      table.sort(collected, function(a, b)
        return a.name < b.name
      end)
      local width = 0
      for _, e in ipairs(collected) do
        width = math.max(width, text_width(display_name(e)))
      end
      state.maxwidth = width
      state.entries_width = width
      state.entries = collected
      state.loading = false
      state.applying = false
      state.update_display(state, collected)
    end

    if #names == 0 then
      finish({})
      return state
    end

    local pending = #names
    local collected = {}
    for _, name in ipairs(names) do
      local full = path .. name
      local function on_stat(err, stat)
        if err or not stat then
          stat = uv.fs_lstat(full)
        end
        if stat then
          collected[#collected + 1] = { name = name, stat = stat }
        end
        pending = pending - 1
        if pending == 0 then
          vim.schedule(function()
            finish(collected)
          end)
        end
      end
      -- luv returns nil without ever calling back when a request fails to
      -- start; count it here or `pending` never reaches 0.
      if not uv.fs_stat(full, on_stat) then
        on_stat('request failed', nil)
      end
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

Browser.rowEntries = function(state, first, last)
  local rows = {}
  local s = first and { first, 0 } or 0
  local e = last and { last, -1 } or -1
  for _, m in ipairs(api.nvim_buf_get_extmarks(state.buf, ns_entry, s, e, { details = true })) do
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
    return {}
  end
  local lo, hi = math.min(a, b), math.max(a, b)
  local rows = Browser.rowEntries(state, lo - 1, hi - 1)
  local list = {}
  for row = lo - 1, hi - 1 do
    if rows[row] then
      list[#list + 1] = rows[row].entry
    end
  end
  return list
end

-- Absolute path for a line. Prefers the entry identity over the line text, so
-- names with leading/trailing blanks or escaped newlines still resolve.
Browser.pathAt = function(state, lnum)
  local line = api.nvim_buf_get_lines(state.buf, lnum - 1, lnum, false)[1]
  if not line then
    return nil
  end
  local entry = entry_on_row(state, lnum - 1)
  if entry and (line == display_name(entry) or strip_sep(vim.trim(line)) == entry.name) then
    return vim.fs.joinpath(state.current_path, entry.name)
  end
  local text = vim.trim(line)
  if text == '' then
    return nil -- used to resolve to current_path and silently reload the dir
  end
  return vim.fs.joinpath(state.current_path, text)
end

Browser.openRow = function(state, lnum, cmd)
  local path = Browser.pathAt(state, lnum)
  if not path then
    return
  end
  if PathOps.isDirectory(path) then
    run_io(Actions.openDirectory(state, path))
  elseif PathOps.isFile(path) then
    Actions.openFile(state, path, cmd or vim.cmd.edit)
  end
end

Browser.setup = function(state)
  return F.IO.fromEffect(function()
    -- Before acting on <CR> in the prompt, make sure the list reflects what was
    -- typed. Otherwise "type a name + Enter" within the debounce/fd window opens
    -- whatever stale entry is under the cursor.
    local function settle(fn)
      if api.nvim_get_current_buf() ~= state.search_buf then
        return false
      end
      local before = state.current_path
      state.on_prompt_changed()
      if state.current_path ~= before then
        return true -- the pending edit navigated somewhere; that was the action
      end
      if state.loading or state.search_engine.busy() then
        state.after_render = fn
        return true
      end
      return false
    end

    local function open_selection(cmd, allow_dir)
      local function go()
        if state.closed then
          return
        end
        if #state.shown == 0 then
          -- Nothing listed (empty dir or no match): treat the prompt as a path.
          -- This used to test #state.entries, the *directory* listing, so in a
          -- non-empty directory a no-match name could never be created.
          local p = PathOps.getSearchPath(state)
          if not p or vim.endswith(p, SEPARATOR) or PathOps.isDirectory(p) then
            return
          end
          if PathOps.isFile(p) then
            return Actions.openFile(state, p, cmd)
          end
          Actions.createAndEdit(state, p, cmd).fork(Notify.err, function() end)
          return
        end
        local path = Browser.pathAt(state, api.nvim_win_get_cursor(state.win)[1])
        if not path then
          return
        end
        if allow_dir and PathOps.isDirectory(path) then
          run_io(Actions.openDirectory(state, path))
        elseif PathOps.isFile(path) then
          Actions.openFile(state, path, cmd)
        end
      end
      return function()
        if not settle(go) then
          go()
        end
      end
    end

    local open = open_selection(vim.cmd.edit, true)

    local keymaps = {
      {
        key = Config.keymaps.open,
        action = function()
          if api.nvim_get_current_buf() == state.buf and api.nvim_get_mode().mode == 'i' then
            return api.nvim_feedkeys(
              api.nvim_replace_termcodes('<CR>', true, false, true),
              'n',
              false
            )
          end
          open()
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
          run_io(Actions.openDirectory(state, parent))
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
            if api.nvim_win_is_valid(state.win) then
              vim.wo[state.win].eventignorewin = ''
            end
          end)
        end,
        buffer = { state.search_buf, state.buf },
      },
      {
        key = Config.keymaps.toggle_hidden,
        action = function()
          state.show_hidden = not state.show_hidden
          Notify.info(string.format('Hidden files %s', state.show_hidden and 'shown' or 'hidden'))
          run_io(Actions.openDirectory(state, state.current_path))
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
          -- direct call: exec_autocmds('CursorMoved') also ran every other
          -- plugin's CursorMoved handlers on each keypress
          state.on_cursor_moved()
        end,
      },
      {
        key = Config.keymaps.backward,
        action = function()
          local pos = api.nvim_win_get_cursor(state.win)
          local count = api.nvim_buf_line_count(state.buf)
          pos[1] = pos[1] - 1 == 0 and count or pos[1] - 1
          api.nvim_win_set_cursor(state.win, pos)
          state.on_cursor_moved()
        end,
      },
      {
        key = { i = SEPARATOR },
        action = function()
          local search_path = PathOps.getSearchPath(state)
          search_path = search_path and (search_path .. SEPARATOR)
          if search_path and PathOps.isDirectory(search_path) then
            run_io(Actions.openDirectory(state, search_path))
          else
            api.nvim_feedkeys(SEPARATOR, 'n', false)
          end
        end,
      },
      {
        key = Config.keymaps.split,
        action = open_selection(vim.cmd.split, false),
        buffer = { state.search_buf, state.buf },
      },
      {
        key = Config.keymaps.vsplit,
        action = open_selection(vim.cmd.vsplit, false),
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
          run_io(Actions.openDirectory(state, curdir))
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
    local r = rows[i - 1]
    if r then
      local entry = r.entry
      if line:find('%S') and not kept[entry] then
        kept[entry] = true
        -- Compare the raw line first. Trimming before comparing meant that any
        -- edit anywhere renamed every file whose name has leading/trailing
        -- blanks (and escaped-newline names to a literal "\n").
        if line ~= display_name(entry) and line ~= entry.name then
          local new = strip_sep(vim.trim(line))
          if new ~= entry.name then
            table.insert(renames, { entry = entry, new = new })
          end
        end
      end
    elseif line:find('%S') then
      table.insert(unmarked, vim.trim(line))
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

-- Re-render what was shown before the edit (no disk access).
local function restore_view(state)
  if state.closed then
    return
  end
  if api.nvim_win_is_valid(state.win) then
    state.before_pos = api.nvim_win_get_cursor(state.win)
  end
  state.update_display(state, state.shown, false, state.total_count)
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
    restore_view(state)
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
      -- the buffer still showed the deletion although nothing happened on disk
      restore_view(state)
      return
    end
  end

  table.sort(plan.creates, function(a, b)
    return select(2, a.name:gsub('/', '')) < select(2, b.name:gsub('/', ''))
  end)

  local focus = plan.creates[1] and plan.creates[1].name
    or (plan.renames[1] and plan.renames[1].new)
  if focus then
    state.target_op = { name = focus:match('^[^/]+') }
  end
  Browser.executeOperations(state, plan)
end

-- Runs deletes, renames, creates in order and STOPS at the first failure.
-- Continuing used to be destructive: with a swap a<->b, if `b -> tmp` failed the
-- later `tmp -> b` rename silently overwrote the original b (fs_rename replaces).
Browser.executeOperations = function(state, plan)
  local steps = {}
  local in_tmp = {} -- two-phase renames currently parked under a temp name
  local n_changes = #plan.deletes + #plan.renames + #plan.creates

  local function ensure_parent(p)
    local dir = vim.fs.dirname(p)
    if vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, 'p')
    end
  end

  if #plan.deletes > 0 then
    if Config.use_trash then
      -- one trash process for the whole batch instead of one per entry
      local paths = {}
      for _, e in ipairs(plan.deletes) do
        paths[#paths + 1] = vim.fs.joinpath(state.current_path, e.name)
      end
      steps[#steps + 1] = function(ok, fail)
        FileOps.moveToTrash(paths).fork(function(err)
          fail('Failed to move to trash: ' .. tostring(err))
        end, ok)
      end
    else
      for _, e in ipairs(plan.deletes) do
        local p = vim.fs.joinpath(state.current_path, e.name)
        steps[#steps + 1] = function(ok, fail)
          -- lstat, not the cached (link-following) stat: a symlink to a
          -- directory must be unlinked, never recursed into.
          local st = uv.fs_lstat(p)
          local task = (st and st.type == 'directory') and FileOps.deleteDirectory(p)
            or FileOps.deleteFile(p)
          task.fork(function(err)
            fail(('Failed to delete %s: %s'):format(e.name, err))
          end, ok)
        end
      end
    end
  end

  local function rename_step(from, to, label, after)
    return function(ok, fail)
      ensure_parent(to)
      FileOps.moveAcross(from, to).fork(function(err)
        fail(('Failed to rename %s: %s'):format(label, err))
      end, function()
        if after then
          after()
        end
        ok()
      end)
    end
  end

  if plan.two_phase then
    local stamp = tostring(uv.hrtime())
    for i, r in ipairs(plan.renames) do
      r.tmp_path =
        vim.fs.joinpath(vim.fs.dirname(r.old_path), ('.dired_tmp_%s_%d'):format(stamp, i))
      steps[#steps + 1] = rename_step(r.old_path, r.tmp_path, r.entry.name, function()
        in_tmp[r] = true
      end)
    end
    for _, r in ipairs(plan.renames) do
      steps[#steps + 1] = rename_step(r.tmp_path, r.new_path, r.new, function()
        in_tmp[r] = nil
      end)
    end
  else
    for _, r in ipairs(plan.renames) do
      steps[#steps + 1] = rename_step(r.old_path, r.new_path, r.new)
    end
  end

  for _, c in ipairs(plan.creates) do
    steps[#steps + 1] = function(ok, fail)
      ensure_parent(c.path)
      if c.is_directory then
        FileOps.createDirectory(c.path).fork(function(err)
          if tostring(err):match('EEXIST') then
            return ok()
          end
          fail('Failed to create directory ' .. c.name .. ': ' .. err)
        end, ok)
      else
        FileOps.createFile(c.path).fork(function(err)
          fail('Failed to create file ' .. c.name .. ': ' .. err)
        end, ok)
      end
    end
  end

  if #steps == 0 then
    return
  end

  state.applying = true
  if api.nvim_buf_is_valid(state.buf) then
    vim.bo[state.buf].modifiable = false
  end
  if api.nvim_win_is_valid(state.win) then
    state.before_pos = api.nvim_win_get_cursor(state.win)
  end

  local function finish(err, at)
    if err then
      local msgs = { err }
      -- put half-swapped entries back under their original names
      for _, r in ipairs(plan.renames) do
        if in_tmp[r] then
          if not uv.fs_lstat(r.old_path) and uv.fs_rename(r.tmp_path, r.old_path) then
            in_tmp[r] = nil
          else
            msgs[#msgs + 1] = ('%s was left at %s'):format(r.entry.name, r.tmp_path)
          end
        end
      end
      Notify.err(
        ('Stopped at step %d/%d, remaining changes not applied:\n%s'):format(
          at,
          #steps,
          table.concat(msgs, '\n')
        )
      )
    else
      Notify.info(string.format('Successfully applied %d changes', n_changes))
    end
    if state.closed then
      return
    end
    run_io(Actions.openDirectory(state, state.current_path))
  end

  local i = 0
  local function next_step()
    i = i + 1
    local step = steps[i]
    if not step then
      return finish()
    end
    local at = i
    local settled = false
    local function fail(err)
      if not settled then
        settled = true
        vim.schedule(function()
          finish(err, at)
        end)
      end
    end
    local ok, thrown = pcall(step, function()
      if not settled then
        settled = true
        vim.schedule(next_step)
      end
    end, fail)
    if not ok then
      fail(tostring(thrown))
    end
  end
  next_step()
end

local function browse_directory(path)
  Config = resolve_config()
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
