# dired.nvim

A file manager similar to Emacs that aims to use functional programming in Lua.


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
