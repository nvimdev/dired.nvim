# dired.nvim

A file manager similar to Emacs that aims to use functional programming in Lua.

![Image](https://github.com/user-attachments/assets/f74cc4da-017e-4cb8-85f0-6cc7b7cbbb0a)

## Usage

option for config
```lua
vim.g.dired = {
    show_hidden = true
}
```

use `:Dired path?`, keymaps in buffer

`<CR>` open `u` go up `q` quite `cf` create file
`cd` create dir `D` delete file/dir `R` rename
`yy` copy `p` paste and cut move `gh` toggle show hidden files
`dd` cut


## License MIT
