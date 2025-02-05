# dired.nvim

A file manager similar to Emacs that aims to use functional programming in Lua.

![Image](https://github.com/user-attachments/assets/f74cc4da-017e-4cb8-85f0-6cc7b7cbbb0a)

## Usage

Default config

```lua
{
  show_hidden = true,
  prompt_start_insert = true,   -- when start dired auto enter insert mode
  prompt_insert_on_open = true, -- when open if mode not in insert auto enter insert mode
  -- i mean insert mode n mean normal mode
  keymaps = {
    open = { i = '<CR>', n = '<CR>' },
    up = 'u',
    quit = { n = 'q', i = '<C-c>' },
    create_file = { n = 'cf', i = '<C-f>' },
    create_dir = { n = 'cd', i = '<C-d>' },
    delete = 'D',
    rename = { n = 'R', i = '<C-r>' },
    copy = 'yy',
    cut = 'dd',
    paste = 'p',
    forward = { i = '<C-n>', n = 'j' },
    backward = { i = '<C-p>', n = 'k' },
  },
}
```

use `:Dired path?`, custom config by using `vim.g.dired` variable.

like custom keymaps in `vim.g.dired` like

```
vim.g.dired = {
   keymaps = { up = { i = '<C-p>', n = 'k' }, down = 'j' -- just normal mode }
}
```

## License MIT
