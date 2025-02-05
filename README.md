# dired.nvim

A file manager similar to Emacs that aims to use functional programming in Lua.

![Image](https://github.com/user-attachments/assets/f74cc4da-017e-4cb8-85f0-6cc7b7cbbb0a)

## Usage

Default config

```lua
vim.g.dired = {
  show_hidden = true,
  prompt_start_insert = true,   -- when start dired auto enter insert mode
  prompt_insert_on_open = true, -- when open if mode not in insert auto enter insert mode
  keymaps = {
    open = { i = '<CR>', n = '<CR>' },
    up = 'u',
    quit = { n = 'q', i = '<C-c>' },
    create_file = 'cf',
    create_dir = 'cd',
    delete = 'D',
    rename = 'R',
    copy = 'yy',
    cut = 'dd',
    paste = 'p',
    forward = { i = '<C-n>', n = 'j' },
    backard = { i = '<C-p>', n = 'k' },
  },
}
```

use `:Dired path?`, keymaps in buffer

`C-N` in insert and normal move donw
`C-P` in insert and normal move up
`j/k` in normal mode same as `C-N/C-P`
`q`   quite in normal mode
`C-C` quite in insert mode
`<CR>` open `u` go up  `cf` create file
`cd` create dir `D` delete file/dir `R` rename
`yy` copy `p` paste and cut move `gh` toggle show hidden files
`dd` cut

custom keymaps with `action = key or { mode = key}` in `vim.g.dired` like

```
vim.g.dired = {
   keymaps = { up = { i = '<C-p>', n = 'k' }, down = 'j' -- just normal mode }
}
```

## License MIT
