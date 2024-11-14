-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Replace l-dash split with oil, and use l-shift-dash for split
vim.keymap.set("n", "<leader>-", vim.cmd.Oil)
vim.keymap.set("n", "<leader>_", ":sb<CR>")
