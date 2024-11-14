return {
  {
    "folke/flash.nvim",
    keys = {
      -- disable the default flash keymap - use f/F instead of s/S, for now defined in keymaps.lua
      { "s", mode = { "n", "x", "o" }, false, desc = "substitute" },
      { "S", mode = { "n", "x", "o" }, false, desc = "Substitute to end of line" },
      -- {
      --   "f",
      --   mode = { "n", "x", "o" },
      --   function()
      --     require("flash").jump()
      --   end,
      --   desc = "Flash",
      -- },
      -- {
      --   "F",
      --   mode = { "n", "o", "x" },
      --   function()
      --     require("flash").treesitter()
      --   end,
      --   desc = "Flash Treesitter",
      -- },
    },
  },
}
