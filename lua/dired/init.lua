local api, uv, ffi = vim.api, vim.uv, require('ffi')
local Iter, mapset = vim.iter, vim.keymap.set
local ops = require('dired.ops')
local FileOps, PathOps = ops.FileOps, ops.PathOps
local ns_id = api.nvim_create_namespace('dired_highlights')
local ns_mark = api.nvim_create_namespace('dired_marks')
local SEPARATOR = vim.uv.os_uname().version:match('Windows') and '\\' or '/'

-- FFI definitions
ffi.cdef([[
typedef unsigned int uv_uid_t;
int os_get_uname(uv_uid_t uid, char *s, size_t len);
]])

---@class KeyMapConfig
---@field open string|table<string, string>
---@field up string|table<string, string>
---@field quit string|table<string, string>
---@field toogle_hidden string|table<string, string>
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
---@field keymaps KeyMapConfig

---@type DiredConfig
local Config = setmetatable({}, {
  __index = function(_, scope)
    local default = {
      show_hidden = true,
      normal_when_fits = false,
      shortcuts = 'sdfhlwertyuopzxcvbnmSDFGHLQWERTYUOPZXCVBNM',
      show_user = false,
      use_trash = true,
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
      },
    }
    if vim.g.dired and vim.g.dired[scope] ~= nil then
      return vim.g.dired[scope]
    end
    return default[scope]
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

UI.Entry = {
  render = function(state, row, entry)
    local formatted = {
      perms = entry.perms or Format.permissions(entry.stat.mode),
      user = entry.user or Format.username(entry.stat.uid),
      size = entry.size or Format.size(entry.stat.size),
      time = entry.date or Format.friendly_time(entry.stat.mtime.sec),
      name = entry.name .. (entry.stat.type == 'directory' and SEPARATOR or ''),
    }
    api.nvim_buf_set_lines(
      state.buf,
      row,
      row + 1,
      false,
      { ('%-' .. (state.maxwidth + 2) .. 's'):format(formatted.name) }
    )
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
      right_gravity = false,
    })

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
      }
    end)
  end,
  event = function(state)
    return F.IO.fromEffect(function()
      state.group = api.nvim_create_augroup('DiredGroup', {})
      api.nvim_create_autocmd('CursorMoved', {
        group = state.group,
        buffer = state.buf,
        callback = function()
          local row = api.nvim_win_get_cursor(state.win)[1] - 1
          state.count_mark = api.nvim_buf_set_extmark(state.search_buf, ns_id, 0, 0, {
            id = state.count_mark or nil,
            virt_text = {
              { ('[%d/%d]   Find File: '):format(row + 1, #state.entries), 'DiredTitle' },
            },
            virt_text_pos = 'inline',
          })

          if api.nvim_win_is_valid(state.win) then
            state.shortcut_manager.recycle(state)
          end
        end,
      })

      api.nvim_create_autocmd({ 'InsertLeave' }, {
        group = state.group,
        buffer = state.buf,
        callback = function()
          Browser.applyChanges(state)
        end,
      })
      return state
    end)
  end,
  monitor = function(state)
    return F.IO.fromEffect(function()
      state.clipboard = {}
      state.vim_reg = {}
      state.operation_mode = nil -- 'visual', 'normal', 'yank', 'delete', 'paste'
      state.operation_start_line = nil
      state.operation_end_line = nil

      vim.on_key(function(key)
        local current_buf = api.nvim_get_current_buf()
        local mode = api.nvim_get_mode().mode
        if current_buf ~= state.buf or api.nvim_get_current_win() ~= state.win then
          return
        end

        if mode == 'no' then
          -- copy
          if key == 'Y' or (key == 'y' and state.vim_reg.last_key == 'y') then
            state.operation_mode = 'yank'
            local cursor_pos = api.nvim_win_get_cursor(state.win)
            local line_idx = cursor_pos[1]
            if state.entries[line_idx] then
              state.clipboard = {
                type = 'copy',
                entries = { state.entries[line_idx] },
                source_path = state.current_path,
              }

              Notify.info('copied one file')
            end

            state.operation_mode = nil
          end

          -- delete
          if key == 'd' and state.vim_reg.last_key == 'd' then
            state.operation_mode = 'delete'
            local cursor_pos = api.nvim_win_get_cursor(state.win)
            local line_idx = cursor_pos[1]
            local op = {
              type = 'delete',
              path = nil,
            }
            if state.entries[line_idx] then
              op.path = vim.fs.joinpath(state.current_path, state.entries[line_idx].name)
              local text = api.nvim_get_current_line():gsub('%s+$', '')
              if vim.endswith(text, SEPARATOR) then
                Notify.info('delete folder ' .. state.entries[line_idx].name)
              else
                Notify.info('delete file ' .. state.entries[line_idx].name)
              end
            end

            vim.schedule(function()
              Browser.executeOperations(state, { op })
              if api.nvim_buf_is_valid(state.search_buf) then
                api.nvim_buf_set_lines(state.search_buf, 0, -1, false, { state.current_path })
                api.nvim_buf_set_extmark(state.search_buf, ns_id, 0, 0, {
                  end_col = api.nvim_strwidth(state.current_path),
                  hl_group = 'DiredPrompt',
                })
              end
            end)
            state.operation_mode = nil
          end
        end

        if mode == 'n' then
          if key == 'p' then
            if state.clipboard and state.clipboard.entries and #state.clipboard.entries > 0 then
              Browser.executeClipboardOperation(state)
            else
              Notify.info('clipboard is empty')
            end
          end

          if key == 'r' or key == 'R' then
            state.operation_mode = 'replace'
            state.operation_start_line = api.nvim_win_get_cursor(state.win)[1]
          end

          if key == 'v' or key == 'V' then
            state.operation_mode = 'visual'
            state.operation_start_line = api.nvim_win_get_cursor(state.win)[1]
          end

          -- cut
          if key == 'D' then
            local cursor_pos = api.nvim_win_get_cursor(state.win)
            local line_idx = cursor_pos[1]
            if state.entries[line_idx] then
              state.clipboard = {
                type = 'cut',
                entries = { state.entries[line_idx] },
                source_path = state.current_path,
              }
              vim.api.nvim_command('normal! dd')
              if api.nvim_get_current_line():match(SEPARATOR .. '$') then
                Notify.info('cut folder ' .. state.entries[line_idx].name)
              else
                Notify.info('cut file ' .. state.entries[line_idx].name)
              end
              return ''
            end
          end
        end

        if
          mode == 'R'
          and state.operation_mode == 'replace'
          and api.nvim_win_get_cursor(state.win)[1] == state.operation_start_line
        then
          vim.schedule(function()
            Browser.applyChanges(state)
          end)
          return
        end

        -- visual mode
        if mode == 'v' or mode == 'V' then
          local cursor_pos = api.nvim_win_get_cursor(state.win)
          state.operation_end_line = cursor_pos[1]

          if key == 'y' then
            local start_line = math.min(state.operation_start_line, state.operation_end_line)
            local end_line = math.max(state.operation_start_line, state.operation_end_line)

            local selected_entries = {}
            for i = start_line, end_line do
              if state.entries[i] then
                table.insert(selected_entries, state.entries[i])
              end
            end

            if #selected_entries > 0 then
              state.clipboard = {
                type = 'copy',
                entries = selected_entries,
                source_path = state.current_path,
              }

              Notify.info(string.format('copied %d files', #selected_entries))
            end

            state.operation_mode = nil
          end

          if key == 'd' or key == 'D' then
            local start_line = math.min(state.operation_start_line, state.operation_end_line)
            local end_line = math.max(state.operation_start_line, state.operation_end_line)

            local selected_entries = {}
            for i = start_line, end_line do
              if state.entries[i] then
                table.insert(selected_entries, state.entries[i])
              end
            end

            if #selected_entries > 0 then
              state.clipboard = {
                type = 'cut',
                entries = selected_entries,
                source_path = state.current_path,
              }

              Notify.info(string.format('cut %d files', #selected_entries))
            end

            state.operation_mode = nil
          end
        end
        state.vim_reg.last_key = key
      end, ns_id, {})

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

  if source_path == destination_path and state.clipboard.type == 'cut' then
    Notify.info('source and target are same, cannot be performed.')
    return
  end

  for _, entry in ipairs(state.clipboard.entries) do
    local source_name = entry.name
    local full_source_path = vim.fs.joinpath(source_path, source_name)
    local target_path = vim.fs.joinpath(destination_path, source_name)

    if source_path == destination_path and state.clipboard.type == 'copy' then
      local base_name = source_name:match('(.+)%..+$') or source_name
      local extension = source_name:match('%.(.+)$') or ''
      if extension ~= '' then
        extension = '.' .. extension
      end

      local i = 1
      local new_name = base_name .. '_copy' .. extension
      target_path = vim.fs.joinpath(destination_path, new_name)

      while vim.fn.filereadable(target_path) == 1 or vim.fn.isdirectory(target_path) == 1 do
        i = i + 1
        new_name = base_name .. '_copy' .. i .. extension
        target_path = vim.fs.joinpath(destination_path, new_name)
      end
    end

    if vim.fn.filereadable(target_path) == 1 or vim.fn.isdirectory(target_path) == 1 then
      if state.clipboard.type == 'cut' then
        Notify.err('target path exists: ' .. target_path)
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
  local completed = 0
  local errors = {}

  local function updateStatus()
    if #errors > 0 then
      Notify.err(string.format('operation done，has %d erros', #errors))
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
      local task = FileOps.move(op.source, op.target)
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

local function create_shortcut_manager()
  local pool = vim.split(Config.shortcuts, '')
  -- {shortcut -> line_num}
  local assigned = {} -- type table<string, int>

  return {
    get = function()
      return assigned
    end,
    reset = function(state)
      for shortcut, _ in pairs(assigned) do
        pcall(vim.keymap.del, 'n', shortcut, { buffer = state.buf })
      end
      assigned = {}
      pool = vim.split(Config.shortcuts, '')
      api.nvim_buf_clear_namespace(state.buf, ns_mark, 0, -1)
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
      local visible = api.nvim_win_call(state.win, function()
        local top = vim.fn.line('w0')
        local bot = vim.fn.line('w$')
        return { top, bot }
      end)

      local new = {}
      for key, lnum in pairs(assigned) do
        if lnum < visible[1] or lnum > visible[2] then
          vim.keymap.del('n', key, { buffer = state.search_buf })
          table.insert(pool, key)
        else
          new[key] = lnum
        end
      end
      assigned = new
    end,
  }
end

local function parse_fd_output(line, current_path)
  if #line == 0 then
    return nil
  end
  local entry = {}
  local data = Iter(vim.split(line, '%s')):map(function(item)
    if #item > 0 then
      return item
    end
  end):totable()
  if #data < 9 then
    return
  end
  entry.perms = data[1]:gsub('@$', '')
  entry.user = data[3]
  entry.size = data[5]
  entry.date = ('%s %s %s'):format(data[6], data[7], data[8])

  local name = data[9]:sub(#current_path + 1)
  if name:sub(1, 1) == '/' or name:sub(1, 1) == '\\' then
    name = name:sub(2)
  end
  entry.name = name
  entry.stat = {
    type = entry.perms:sub(1, 1) == 'd' and 'directory' or 'file',
  }
  return entry
end

local function create_debounced_search()
  local timer = nil
  local last_search = ''
  local is_searching = false
  ---@type vim.SystemObj | nil
  local current_job = nil
  local search_id = 0
  local handled_results = {}

  local function cleanup()
    if timer and timer:is_active() then
      timer:stop()
      timer:close()
      timer = nil
    end
    if current_job and not current_job:is_closing() then
      current_job:kill(9)
      current_job = nil
    end
  end

  local reset = function()
    last_search = ''
    is_searching = false
    handled_results = {}
    search_id = search_id + 1
    cleanup()
  end

  local function process_and_display_results(results, search_text, callback, id)
    if id ~= search_id then
      return
    end

    local filters = {}
    local names = Iter(results):map(function(entry)
      return entry.name
    end):totable()
    local res = vim.fn.matchfuzzypos(names, search_text)
    local maxwidth = 0
    for _, entry in ipairs(results) do
      for k, v in ipairs(res[1]) do
        if v == entry.name then
          maxwidth = math.max(maxwidth, api.nvim_strwidth(v))
          entry.match_pos = res[2][k]
          entry.score = res[3][k] or 0
          table.insert(filters, entry)
        end
      end
    end

    handled_results = vim.list_extend(handled_results, filters)
    table.sort(handled_results, function(a, b)
      return a.score > b.score
    end)
    callback(vim.list_slice(handled_results, 1, 80), #handled_results, maxwidth)
  end

  -- TODO: support fuzzy search ?
  local function execute_search(state, search_text, callback)
    if search_text == last_search then
      return
    end
    reset()
    is_searching = true
    last_search = search_text
    search_id = search_id + 1
    local current_search_id = search_id
    current_job = vim.system({
      'fd',
      '-l',
      '-i',
      '-H',
      '--max-depth',
      '5',
      '--color',
      'never',
      search_text,
      state.current_path,
    }, {
      text = true,
      stdout = function(_, data)
        if current_search_id ~= search_id then
          return
        end

        local results = {}
        if data then
          for _, line in ipairs(vim.split(data, '\n')) do
            if #line > 0 then
              local entry = parse_fd_output(line, state.current_path)
              if entry then
                local len = #entry.name + (entry.stat.type == 'directory' and 1 or 0)
                state.maxwidth = math.max(state.maxwidth or 0, len)
                table.insert(results, entry)
              end
            end
          end

          if current_search_id == search_id and #results > 0 then
            vim.schedule(function()
              process_and_display_results(results, search_text, callback, current_search_id)
            end)
          end
        end
      end,
    }, function(obj)
      if current_search_id ~= search_id then
        return
      end

      if #handled_results == 0 then
        vim.schedule(function()
          process_and_display_results({}, search_text, callback, current_search_id)
        end)
      end

      if obj.code ~= 0 and obj.code ~= 1 then
        Notify.err('Search error: ' .. (obj.stderr or 'Unknown error'))
      end
    end)
  end

  return {
    search = function(state, search_text, callback, delay)
      delay = delay or 100
      if is_searching then
        reset()
      end
      timer = assert(vim.uv.new_timer())
      timer:start(delay, 0, function()
        execute_search(state, search_text, callback)
      end)
    end,
    destroy = cleanup,
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
          s.original_entries = {}
          s.clipboard = {}
          s.shortcut_manager = create_shortcut_manager()
          s.search_engine = create_debounced_search()
          s.initialized = false

          -- Function to update display with entries
          local function update_display(new_state, entries_to_show, change_mode)
            vim.schedule(function()
              if next(s.shortcut_manager.get()) ~= nil then
                s.shortcut_manager.reset(new_state)
              end

              if api.nvim_buf_is_valid(new_state.buf) then
                api.nvim_buf_set_lines(new_state.buf, 0, -1, false, {})
                api.nvim_buf_clear_namespace(new_state.buf, ns_id, 0, -1)

                state.count_mark = api.nvim_buf_set_extmark(new_state.search_buf, ns_id, 0, 0, {
                  id = state.count_mark or nil,
                  virt_text = {
                    {
                      ('[%d/%d]   Find File: '):format(
                        #entries_to_show > 0 and 1 or 0,
                        #entries_to_show
                      ),
                      'DiredTitle',
                    },
                  },
                  virt_text_pos = 'inline',
                })

                if #entries_to_show == 0 then
                  return
                end

                vim.bo[new_state.buf].modifiable = true
                for i, entry in ipairs(entries_to_show) do
                  UI.Entry.render(new_state, i - 1, entry)
                  -- no need render more than window height
                  if i + 1 > 80 then
                    break
                  end
                end
              end

              local visible_end = api.nvim_buf_line_count(new_state.buf)
              for i = 1, visible_end do
                new_state.shortcut_manager.assign(new_state, i - 1)
              end

              if change_mode == nil then
                change_mode = true
              end
              if
                change_mode
                and Config.normal_when_fits
                and #entries_to_show <= api.nvim_win_get_height(new_state.win)
              then
                api.nvim_feedkeys(api.nvim_replace_termcodes('<ESC>', true, false, true), 'n', true)
              end

              if not s.initialized then
                api.nvim_buf_attach(state.search_buf, false, {
                  on_lines = function()
                    local line = api.nvim_buf_get_text(state.search_buf, 0, 0, 0, -1, {})[1]
                    if state.last_line and line .. SEPARATOR == state.last_line then
                      local parent_path = vim.fs.dirname(vim.fs.normalize(state.last_line))
                        .. SEPARATOR
                      vim.schedule(function()
                        Actions.openDirectory(state, parent_path).run()
                      end)
                      return
                    end

                    local query = line:sub(#(state.abbr_path or state.current_path) + 1)
                    query = query:gsub('^' .. SEPARATOR, '')

                    -- Empty query or directory navigation
                    if query == '' or query:match(SEPARATOR .. '$') then
                      Actions.openDirectory(state, state.current_path).run()
                      return
                    end
                    state.entries = {}
                    state.search_engine.search(state, query, function(entries, count, maxwidth)
                      state.entries = vim.list_extend(state.entries, entries)
                      state.maxwidth = maxwidth
                      if count > 100 then
                        state.count_mark =
                          api.nvim_buf_set_extmark(new_state.search_buf, ns_id, 0, 0, {
                            id = state.count_mark or nil,
                            virt_text = {
                              {
                                ('[1/%d]   Find File: '):format(count),
                                'DiredTitle',
                              },
                            },
                            virt_text_pos = 'inline',
                          })
                        update_display(state, vim.list_slice(entries, 1, 80))
                        return
                      end
                      update_display(state, entries)
                    end, 50)
                  end,
                  on_detach = function()
                    if state.search_engine then
                      state.search_engine.destroy()
                    end
                  end,
                })
              end
              s.initialized = true
            end)
          end

          -- Add the update_display function to state for later use
          s.update_display = update_display
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
      Notify.err('Failed to read directory')
      return
    end

    -- Helper function to collect directory entries
    local function collectEntries()
      local entries = {}
      while true do
        local name = uv.fs_scandir_next(handle)
        if not name then
          break
        end
        table.insert(entries, name)
      end
      return entries
    end

    -- Filter and process entries
    local function processEntries(entries)
      return Iter(entries)
        :map(function(name)
          if state.show_hidden or not name:match('^%.') then
            return name
          end
          return nil
        end)
        :filter(function(name)
          return name ~= nil
        end)
        :totable()
    end

    -- Convert entries to tasks
    local function createStatTasks(filtered_entries)
      return Iter(filtered_entries):map(function(name)
        return {
          name = name,
          path = vim.fs.joinpath(path, name),
        }
      end):totable()
    end

    local entries = collectEntries()
    local filtered = processEntries(entries)
    local tasks = createStatTasks(filtered)
    local pending = { count = #tasks }
    local collected_entries = {}

    state.current_path = path
    if SEPARATOR ~= '\\' then
      state.abbr_path = state.current_path:gsub(vim.env.HOME, '~')
    end
    -- If no tasks, update immediately
    if #tasks == 0 then
      state.entries = {}
      state.original_entries = {}
      state.update_display(state, {})
      return state
    end

    -- Execute stat operations
    for _, task in ipairs(tasks) do
      uv.fs_stat(task.path, function(err, stat)
        if not err and stat then
          table.insert(collected_entries, {
            name = task.name,
            stat = stat,
          })
          state.maxwidth = math.max(state.maxwidth or 0, #task.name)
        end
        pending.count = pending.count - 1

        if pending.count == 0 then
          -- Sort entries
          table.sort(collected_entries, function(a, b)
            return a.name < b.name
          end)

          state.entries = collected_entries
          state.original_entries = vim.deepcopy(collected_entries)

          vim.schedule(function()
            if
              api.nvim_buf_is_valid(state.buf)
              and api.nvim_win_is_valid(state.win)
              and api.nvim_buf_is_valid(state.search_buf)
              and api.nvim_win_is_valid(state.search_win)
            then
              -- Execute all updates
              state.update_display(state, collected_entries)
            end
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

      vim.uv.fs_mkdir(dir_path, 493, function(err)
        if err and not err:match('EEXIST') then
          reject('Failed to create directory: ' .. err)
          return
        end

        FileOps.createFile(path).fork(reject, function()
          vim.schedule(function()
            api.nvim_win_close(state.win, true)
            api.nvim_win_close(state.search_win, true)
            vim.cmd.stopinsert()
            action(path)
            resolve(state)
          end)
        end)
      end)
    end,
  }
end

Actions.openDirectory = function(state, path)
  return F.IO.chain(F.IO.of(state), function(s)
    return F.IO.chain(Browser.refresh(s, path), function(refreshed_state)
      return F.IO.fromEffect(function()
        if api.nvim_buf_is_valid(refreshed_state.search_buf) then
          path = refreshed_state.abbr_path or refreshed_state.current_path
          state.last_line = path
          api.nvim_buf_set_lines(refreshed_state.search_buf, 0, -1, false, { path })
          local end_col = api.nvim_strwidth(path)
          api.nvim_win_set_cursor(refreshed_state.search_win, { 1, end_col })
          api.nvim_buf_set_extmark(refreshed_state.search_buf, ns_id, 0, 0, {
            end_col = end_col,
            hl_group = 'DiredPrompt',
          })
          api.nvim_buf_set_extmark(refreshed_state.search_buf, ns_id, 0, 0, {
            hl_group = 'DiredTitle',
            hl_mode = 'combine',
          })
        end
        if
          api.nvim_get_current_buf() == refreshed_state.search_buf
          and api.nvim_get_mode().mode ~= 'i'
        then
          vim.cmd('startinsert!')
        end
        return refreshed_state
      end)
    end)
  end)
end

Actions.openFile = function(state, path, action)
  api.nvim_win_close(state.win, true)
  api.nvim_win_close(state.search_win, true)
  vim.cmd.stopinsert()
  vim.schedule(function()
    action(path)
  end)
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
          local new_path = PathOps.getSelectPath(state)
          if PathOps.isDirectory(new_path) then
            Actions.openDirectory(state, new_path).run()
          elseif PathOps.isFile(new_path) then
            Actions.openFile(state, new_path, vim.cmd.edit)
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
          api.nvim_win_close(state.win, true)
          api.nvim_win_close(state.search_win, true)
          vim.cmd.stopinsert()
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
        key = Config.keymaps.toogle_hidden,
        action = function()
          state.show_hidden = not state.show_hidden
          Notify.info(string.format('Hidden files %s', state.show_hidden and 'shown' or 'hidden'))
          Browser.refresh(state, state.current_path).run()
        end,
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
          local search_path = PathOps.getSearchPath(state) .. SEPARATOR
          if PathOps.isDirectory(search_path) then
            Actions.openDirectory(state, search_path).run()
          end
        end,
      },
      {
        key = Config.keymaps.split,
        action = function()
          local new_path = PathOps.getSelectPath(state)
          local search_path = PathOps.getSearchPath(state)
          local pos = api.nvim_win_get_cursor(state.win)

          if
            not PathOps.isDirectory(search_path)
            and not PathOps.isFile(search_path)
            and pos[1] ~= 3 -- no result
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
          local pos = api.nvim_win_get_cursor(state.win)

          if
            not PathOps.isDirectory(search_path)
            and not PathOps.isFile(search_path)
            and pos[1] ~= 3 -- no result
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
          local curdir = vim.fs.dirname(api.nvim_buf_get_name(vim.b[state.search_buf].curbuf))
          if not curdir:match(SEPARATOR .. '$') then
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
        vim.iter(k):map(function(item)
          if map.buffer and type(map.buffer) == 'table' then
            for _, b in ipairs(map.buffer) do
              mapset(m, item, map.action, { buffer = b })
            end
          else
            mapset(m, item, map.action, { buffer = map.buffer or state.search_buf })
          end
        end)
      end
    end

    Iter(keymaps):map(function(map)
      nmap(map)
    end)

    mapset('n', 'G', function()
      api.nvim_set_current_win(state.win)
      api.nvim_feedkeys(api.nvim_replace_termcodes('G', true, false, true), 'n', false)
    end, { buffer = state.search_buf })
    return state
  end)
end

Browser.applyChanges = function(state)
  local path = state.current_path
  local original_entries = state.original_entries
  local original_names = {}
  for _, entry in ipairs(original_entries) do
    original_names[entry.name .. (entry.stat.type == 'directory' and SEPARATOR or '')] = entry
  end
  local buffer_lines = api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local current_names = {}
  for _, line in ipairs(buffer_lines) do
    local name = line:gsub('%s+', '')
    if name and #name > 0 then
      current_names[name] = true
    end
  end
  local to_create = {}
  local to_delete = {}
  local operations = {}

  -- rename
  local curline = api.nvim_win_get_cursor(state.win)[1]
  local curtext = buffer_lines[curline]:gsub('%s+', '')
  if
    state.entries[curline]
    and curtext ~= state.entries[curline].name
    and #buffer_lines == #state.entries
  then
    local old = state.entries[curline].name
    local new = curtext
    local old_name = old:gsub(SEPARATOR .. '$', '')
    local new_name = new:gsub(SEPARATOR .. '$', '')
    if not new_name:find('%w') then
      return
    end

    local old_path = vim.fs.joinpath(path, old_name)
    local new_path = vim.fs.joinpath(path, new_name)

    table.insert(operations, {
      type = 'rename',
      old_path = old_path,
      new_path = new_path,
    })
    return Browser.executeOperations(state, operations)
  end

  for name, _ in pairs(original_names) do
    if not current_names[name] then
      table.insert(to_delete, name)
    end
  end

  for name, _ in pairs(current_names) do
    if not original_names[name] then
      table.insert(to_create, name)
    end
  end

  -- Add recursive directory scanning for deletion
  local function add_delete_operations_recursive(fullpath, name, entry, operations)
    -- If it's a directory, recursively scan and add delete operations for contents
    if entry.stat.type == 'directory' then
      local handle = uv.fs_scandir(fullpath)
      if handle then
        local subdirs = {}
        local files = {}

        -- Collect all subdirectories and files
        while true do
          local entry_name = uv.fs_scandir_next(handle)
          if not entry_name then
            break
          end

          local entry_path = vim.fs.joinpath(fullpath, entry_name)
          local entry_stat = uv.fs_stat(entry_path)

          if entry_stat then
            if entry_stat.type == 'directory' then
              table.insert(subdirs, { name = entry_name, path = entry_path, stat = entry_stat })
            else
              table.insert(files, { name = entry_name, path = entry_path })
            end
          end
        end

        -- Process subdirectories recursively (depth-first)
        for _, subdir in ipairs(subdirs) do
          add_delete_operations_recursive(
            subdir.path,
            subdir.name,
            { stat = subdir.stat },
            operations
          )
        end

        -- Process files
        for _, file in ipairs(files) do
          table.insert(operations, {
            type = 'delete',
            path = file.path,
            is_directory = false,
            name = file.name,
          })
        end
      end
    end

    -- Finally, add an operation to delete this item
    table.insert(operations, {
      type = 'delete',
      path = fullpath,
      is_directory = entry.stat.type == 'directory',
      name = name,
    })
  end

  for _, name in ipairs(to_delete) do
    local clean_name = name:gsub(SEPARATOR .. '$', '')
    local fullpath = vim.fs.joinpath(path, clean_name)
    local entry = original_names[name]

    add_delete_operations_recursive(fullpath, clean_name, entry, operations)
  end

  table.sort(to_create, function(a, b)
    local a_depth = select(2, a:gsub(SEPARATOR, '')) or 0
    local b_depth = select(2, b:gsub(SEPARATOR, '')) or 0
    return a_depth < b_depth
  end)

  for _, name in ipairs(to_create) do
    local is_directory = name:match(SEPARATOR .. '$') ~= nil
    local clean_name = name:gsub(SEPARATOR .. '$', '')
    if clean_name:find(SEPARATOR) then
      local path_parts = vim.split(clean_name, SEPARATOR, { plain = true })
      local current_path = path
      for i = 1, #path_parts - 1 do
        local dir_name = path_parts[i]
        local dir_path = vim.fs.joinpath(current_path, dir_name)
        if vim.fn.isdirectory(dir_path) ~= 1 then
          table.insert(operations, {
            type = 'create',
            path = dir_path,
            is_directory = true,
            name = dir_name,
          })
        end
        current_path = dir_path
      end
      local last_part = path_parts[#path_parts]
      local final_path = vim.fs.joinpath(current_path, last_part)
      table.insert(operations, {
        type = 'create',
        path = final_path,
        is_directory = is_directory,
        name = last_part,
      })
    else
      local fullpath = vim.fs.joinpath(path, clean_name)
      table.insert(operations, {
        type = 'create',
        path = fullpath,
        is_directory = is_directory,
        name = clean_name,
      })
    end
  end

  if #operations == 0 then
    Notify.info('No changes detected')
    return
  end
  Browser.executeOperations(state, operations)
end

Browser.executeOperations = function(state, operations)
  local total = #operations
  local errors = {}

  local function updateStatus()
    if #errors > 0 then
      Notify.err(string.format('Completed with %d errors', #errors))
      for _, err in ipairs(errors) do
        Notify.err(err)
      end
    else
      Notify.info(string.format('Successfully applied %d changes', total))
    end
    api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
    Browser.refresh(state, state.current_path).run()
  end

  local function executeNextOperation(index)
    if index > #operations then
      updateStatus()
      return
    end

    local op = operations[index]

    if op.type == 'delete' then
      local task
      if Config.use_trash then
        task = FileOps.moveToTrash(op.path)
        Notify.info(string.format('Moving to trash: %s', op.name))
      else
        task = op.is_directory and FileOps.deleteDirectory(op.path) or FileOps.deleteFile(op.path)
      end

      task.fork(function(err)
        local action = Config.use_trash and 'move to trash' or 'delete'
        table.insert(errors, string.format('Failed to %s %s: %s', action, op.name, err))
        vim.schedule(function()
          executeNextOperation(index + 1)
        end)
      end, function()
        vim.schedule(function()
          executeNextOperation(index + 1)
        end)
      end)
    elseif op.type == 'create' then
      if op.is_directory then
        FileOps.createDirectory(op.path).fork(function(err)
          if not err:match('EXIST') then
            table.insert(errors, 'Failed to create directory ' .. op.name .. ': ' .. err)
          end
          vim.schedule(function()
            executeNextOperation(index + 1)
          end)
        end, function()
          vim.schedule(function()
            executeNextOperation(index + 1)
          end)
        end)
      else
        FileOps.createFile(op.path, '').fork(function(err)
          table.insert(errors, 'Failed to create file ' .. op.name .. ': ' .. err)
          vim.schedule(function()
            executeNextOperation(index + 1)
          end)
        end, function()
          vim.schedule(function()
            executeNextOperation(index + 1)
          end)
        end)
      end
    elseif op.type == 'rename' then
      FileOps.move(op.old_path, op.new_path).fork(function(err)
        table.insert(errors, 'Failed to rename ' .. op.name .. ': ' .. err)
        vim.schedule(function()
          executeNextOperation(index + 1)
        end)
      end, function()
        vim.schedule(function()
          executeNextOperation(index + 1)
        end)
      end)
    end
  end

  executeNextOperation(1)
end

local function browse_directory(path)
  path = path:find(SEPARATOR .. '$') and path or path .. SEPARATOR

  F.IO
    .chain(Browser.State.create(path), function(state)
      return F.IO.chain(Browser.setup(state), function(s)
        return Actions.openDirectory(s, path)
      end)
    end)
    .run()
end

return { browse_directory = browse_directory }
