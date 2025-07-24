-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Work around something slow in zsh startup
-- This allows us to swap between nvim and tmux panes without lag
vim.opt.shell = "/bin/bash -i"

-- Disable minipairs. Pairs are the worst
vim.g.minipairs_disable = true

-- Force project root to always be the cwd
-- Without this, opening different files in mono-repo locks the Find Files dir to
-- Something like the nearest package.json or tsconfig or something
vim.g.root_spec = { "cwd" }

-- Restore use of Telescope for find files
vim.g.lazyvim_picker = "telescope"

-- Use ESLint for formatting instead of Prettier
vim.g.lazyvim_eslint_auto_format = true
