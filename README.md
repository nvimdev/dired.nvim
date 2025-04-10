# dired.nvim

A file manager similar to Emacs that aims to use Vim operations to execute file
operations and functional programming in Lua.

## Usage

Default config

```lua
{
      show_hidden = true,
      normal_when_fits = true,
      file_dir_based = true,
      shortcuts = 'sdfhlwertyuopzxcvbnmSDFGHLQWERTYUOPZXCVBNM',
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
}
```

Works like Emacs

```lua
vim.keymap.set({'n', 'i'}, '<C-X><C-f>', '<cmd>Dired<CR>')
```

use `:Dired path?`, custom config by using `vim.g.dired` variable.

## License MIT
