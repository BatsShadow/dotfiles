return {
  -- {
  --   "loctvl842/monokai-pro.nvim",
  --   lazy = false,
  --   priority = 1000,
  --   opts = {
  --     transparent_background = true,
  --     filter = "spectrum",
  --   },
  --   config = function(_, opts)
  --     local monokai = require("monokai-pro")
  --     monokai.setup(opts)
  --     monokai.load()
  --   end,
  -- },
  {
    "akinsho/bufferline.nvim",
    enabled = false,
  },
  {
    "catppuccin/nvim",
    lazy = false,
    name = "catppuccin",
    priority = 1000,
    opts = {
      flavour = "mocha",
      transparent_background = true,
    },
  },
  {
    "LazyVim/LazyVim",
    opts = {
      -- colorscheme = "monokai-pro",
      colorscheme = "catppuccin",
    },
  },
  {
    "folke/noice.nvim",
    config = {
      cmdline = {
        view = "cmdline",
        format = {
          cmdline = { icon = ":" },
        },
      },
    },
  },
}
