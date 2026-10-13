# system.nvim

A very simple plugin with one job: run any external system command and see the results in your editor.

The idea is heavily inspired by emacs' [compile-mode](https://emacsredux.com/blog/2026/03/06/mastering-compilation-mode/), which lets you elegantly handle compiler output as a buffer and **navigate** to locations referenced in that output.

All this plugin does is wrap [vim.system](https://neovim.io/doc/user/lua/#_lua-module:-vim.system) with what I think is an extremely ergonomic api for 1) running any system command or chain of system commands and 2) sending all output of the command to one of many targets (scratch buffer, quickfix, echo, etc) and one of many positions (right, float, bot, etc).


## Installation
#### vim.pack (nvim 0.12+)
```lua
vim.pack.add({ "https://github.com/edisj/system.nvim" })
```

## Usage

```vim
:System pwd
:System target=quickfix pos=right rg <pat> --color=always --line-number
:System target=buf pos=bot gcc -o hello hello.c && ./hello
:System target=echo cwd=$HOME ls -laF --color=always
```

## Similar Plugins
- https://github.com/ej-shafran/compile-mode.nvim
- https://github.com/stevearc/overseer.nvim
