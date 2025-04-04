# dired.nvim

A file manager similar to Emacs that aims to use Vim operations to execute file
operations and functional programming in Lua.

## Usage

dired.nvim supports search, creation, and file operations. After making changes
to a buffer using Vim commands, you can execute file operations through execute.
For example, if you want to delete one or more files, you can press <C-j> to switch
to the displayed buffer, then use commands like dd, D, or VcountD. Afterward,
press <C-w> to execute the operation. To create a file, you can directly type the
file name or nested folders, like a/b/c.txt, which will create the folders a, b,
and then the file c.txt. Note that renaming can be performed alongside creation,
but it cannot be done together with deletion.

Default config

```lua
{
      show_hidden = true,
      enable_fuzzy = true,
      prompt_insert_on_open = true,
      keymaps = {
        open = { i = '<CR>', n = '<CR>' },
        up = { i = '<C-u>', n = '<C-u>' },
        quit = { n = { 'q', '<ESC>' }, i = '<C-c>' },
        forward = { i = '<C-n>', n = 'j' }, -- both on search and main buffer
        backward = { i = '<C-p>', n = 'k' }, -- both on search and main buffer
        split = { n = 'gs', i = '<C-s>' }, -- both on search and main buffer
        vsplit = { n = 'gv', i = '<C-v>' }, -- both on search and main buffer
        switch = { i = '<C-j>' }, -- only search buffer
        execute = { n = '<C-w>', i = '<C-w>' }, -- both on search and main buffer
      },
}
```

Works like Emacs

```lua
vim.keymap.set({'n', 'i'}, '<C-X><C-f>', '<cmd>Dired<CR>')
```

use `:Dired path?`, custom config by using `vim.g.dired` variable.

## License MIT
