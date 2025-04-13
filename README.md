# dired.nvim

Intergrated Emacs `find-files` and `dired` that aims to use Vim operations to
execute file operations and functional programming in Lua.

Works like Emacs

```lua
vim.keymap.set({'n', 'i'}, '<C-X><C-f>', '<cmd>Dired<CR>')
```

use `:Dired path?`, custom config by using `vim.g.dired` variable.

## License MIT
