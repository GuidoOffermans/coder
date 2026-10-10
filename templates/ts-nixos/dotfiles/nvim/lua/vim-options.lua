vim.cmd("set expandtab")
vim.cmd("set tabstop=2")
vim.cmd("set softtabstop=2")
vim.cmd("set shiftwidth=2")

vim.cmd("set termguicolors")

vim.cmd("let g:gruvbox_contrast_dark='hard'")
vim.cmd("let g:gruvbox_contrast_light='hard'")

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

vim.opt.swapfile = false

vim.keymap.set('n', '<leader>h', ':nohlsearch<CR>')
vim.wo.number = true
