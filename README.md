# dired.nvim

A file manager similar to Emacs that aims to use functional programming in Lua.

![Image](https://github.com/user-attachments/assets/f74cc4da-017e-4cb8-85f0-6cc7b7cbbb0a)

## Usage

Default config

```lua
{
  show_hidden = true,
  mark = '⚑',
  enable_fuzzy = true,
  prompt_start_insert = true,   -- when start dired auto enter insert mode
  prompt_insert_on_open = true, -- when open if mode not in insert auto enter insert mode
  -- i mean insert mode n mean normal mode
  keymaps = {
    open = { i = '<CR>', n = '<CR>' },
    up = 'u',
    quit = { n = { 'q', '<ESC>' }, i = '<C-c>' },
    create_file = { n = 'cf', i = '<C-f>' },
    create_dir = { n = 'cd', i = '<C-d>' },
    delete = 'D',
    rename = { n = 'R', i = '<C-r>' },
    copy = 'yy',
    cut = 'dd',
    paste = 'p',
    forward = { i = '<C-n>', n = 'j' },
    backward = { i = '<C-p>', n = 'k' },
    mark = { n = 'm', i = '<A-m>' },
    split = { n = 's', i = '<C-s>' },
    vsplit = { n = 'v', i = '<C-v>' },
  },
}
```

Works like Emacs

```lua
vim.keymap.set({'n', 'i'}, '<C-X><C-f>', '<cmd>Dired<CR>')
```

use `:Dired path?`, custom config by using `vim.g.dired` variable.

**[VS/SP]Open** can also create nested dir and file when not exists.

like custom keymaps in `vim.g.dired` like

```lua
vim.g.dired = {
   keymaps = { up = { i = '<C-p>', n = 'k' }, down = 'j' -- just normal mode }
}
```

## License MIT
