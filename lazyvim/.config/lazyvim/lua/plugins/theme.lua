return {

  {
    "akinsho/bufferline.nvim",
    enabled = false,
  },
  {
    "tiagovla/tokyodark.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      transparent_background = true,
    },
    config = function(_, opts)
      require("tokyodark").setup(opts) -- calling setup is optional
      vim.cmd([[colorscheme tokyodark]])
    end,
  },
  -- {
  --   "LazyVim/LazyVim",
  --   opts = {
  --     -- colorscheme = "monokai-pro",
  --     colorscheme = "catppuccin",
  --   },
  -- },
  {
    "folke/snacks.nvim",
    opts = {
      dashboard = { enabled = false },
    },
  },
}
