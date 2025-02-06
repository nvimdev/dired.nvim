local api = vim.api
local ns_cmdline = api.nvim_create_namespace('dired_cmdline')

local FloatingCmdline = {}

FloatingCmdline.state = {
  buf = nil,
  win = nil,
  is_visible = false,
  current_cmdtype = nil,
  callback = nil,
  orig_win = nil,
}

function FloatingCmdline.create()
  -- Create buffer if not exists
  if not FloatingCmdline.state.buf then
    FloatingCmdline.state.buf = api.nvim_create_buf(false, true)
    vim.bo[FloatingCmdline.state.buf].buftype = 'nofile'
    vim.bo[FloatingCmdline.state.buf].modifiable = true
    vim.bo[FloatingCmdline.state.buf].bufhidden = 'wipe'
  end

  -- Calculate window size and position
  local width = 40 -- Fixed width for confirmation dialog
  local height = 1
  local pos = api.nvim_win_get_cursor(0)
  local WIDTH = api.nvim_win_get_width(0)

  -- Create window if not exists
  if not FloatingCmdline.state.win then
    FloatingCmdline.state.win = api.nvim_open_win(FloatingCmdline.state.buf, false, {
      relative = 'win',
      win = api.nvim_get_current_win(),
      width = width,
      height = height,
      bufpos = { pos[1] + 1, math.floor((WIDTH - width) / 2) },
      style = 'minimal',
      border = 'rounded',
      focusable = true,
      noautocmd = false,
    })
  end

  -- Setup local keymaps
  local opts = { buffer = FloatingCmdline.state.buf, noremap = true, silent = true }

  -- For confirmation dialogs
  vim.keymap.set({ 'n', 'i' }, 'y', function()
    if FloatingCmdline.state.current_cmdtype == 'confirm' then
      FloatingCmdline.handle_input('y')
    else
      return 'y'
    end
  end, opts)

  vim.keymap.set({ 'n', 'i' }, 'n', function()
    if FloatingCmdline.state.current_cmdtype == 'confirm' then
      FloatingCmdline.handle_input('n')
    else
      return 'n'
    end
  end, opts)

  -- General keymaps
  vim.keymap.set({ 'n', 'i' }, '<CR>', function()
    FloatingCmdline.handle_input(api.nvim_get_current_line())
  end, opts)

  vim.keymap.set({ 'n', 'i' }, '<Esc>', function()
    FloatingCmdline.hide()
  end, opts)

  vim.keymap.set({ 'n', 'i' }, '<C-c>', function()
    FloatingCmdline.hide()
  end, opts)
end

FloatingCmdline.show = vim.schedule_wrap(function(cmdtype, prompt, callback)
  -- Store original window
  FloatingCmdline.state.orig_win = api.nvim_get_current_win()
  FloatingCmdline.state.current_cmdtype = cmdtype
  FloatingCmdline.state.callback = callback

  FloatingCmdline.create()
  if cmdtype == 'notify' then
    vim.defer_fn(function()
      vim.schedule(function()
        FloatingCmdline.hide(false)
      end)
    end, 1000)
  end

  vim.schedule(function()
    -- Setup buffer content
    api.nvim_buf_set_lines(FloatingCmdline.state.buf, 0, -1, false, { prompt })
    if cmdtype ~= 'notify' then
      api.nvim_set_current_win(FloatingCmdline.state.win)
      api.nvim_feedkeys(api.nvim_replace_termcodes('A', true, false, true), 'n', false)
    end
    FloatingCmdline.state.is_visible = true
  end)
end)

function FloatingCmdline.hide(back_orig)
  if FloatingCmdline.state.win and api.nvim_win_is_valid(FloatingCmdline.state.win) then
    api.nvim_win_close(FloatingCmdline.state.win, true)
    FloatingCmdline.state.win = nil
    FloatingCmdline.state.buf = nil
  end

  -- Return to original window
  vim.schedule(function()
    if
      back_orig
      and FloatingCmdline.state.orig_win
      and api.nvim_win_is_valid(FloatingCmdline.state.orig_win)
    then
      api.nvim_set_current_win(FloatingCmdline.state.orig_win)
    end
  end)

  FloatingCmdline.state.is_visible = false
  FloatingCmdline.state.current_cmdtype = nil
  FloatingCmdline.state.callback = nil
  FloatingCmdline.state.orig_win = nil
end

function FloatingCmdline.handle_input(input)
  if FloatingCmdline.state.callback then
    if FloatingCmdline.state.current_cmdtype == 'confirm' then
      FloatingCmdline.state.callback(input:lower() == 'y')
    else
      FloatingCmdline.state.callback(input)
    end
  end

  FloatingCmdline.hide()
end

-- Setup UI event handlers
local function setup_ui_events()
  vim.ui_attach(ns_cmdline, {
    ext_cmdline = true,
    ext_messages = true,
  }, function(event, ...)
    local args = { ... }
    if event == 'cmdline_show' then
      local content = args[1]
      local cmdtype = args[3]

      if cmdtype == 'confirm' then
        local cmdline = ''
        if content and content[1] then
          cmdline = content[1][2] or ''
        end
        FloatingCmdline.show(cmdtype, cmdline, function(result)
          if FloatingCmdline.state.callback then
            FloatingCmdline.state.callback(result)
          end
        end)
        return true
      end
    elseif event == 'cmdline_hide' then
      if FloatingCmdline.state.is_visible then
        FloatingCmdline.hide()
        return true
      end
    end
  end)
end

return {
  setup = setup_ui_events,
  show_confirm = function(prompt, callback)
    FloatingCmdline.show('confirm', prompt, callback)
  end,
  show_notify = function(msg)
    FloatingCmdline.show('notify', msg)
  end,
  show_cmdline = function(prompt, callback)
    FloatingCmdline.show(':', prompt, callback)
  end,
  detach = function()
    vim.ui_detach(ns_cmdline)
  end,
}
