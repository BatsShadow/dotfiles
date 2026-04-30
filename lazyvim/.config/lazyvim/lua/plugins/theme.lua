return {
  {
    "akinsho/bufferline.nvim",
    enabled = false,
  },
  {
    "Shatur/neovim-ayu",
    lazy = false,
    opts = {},
    config = function()
      require("ayu").setup({
        mirage = false,
        overrides = {
          Normal = { bg = "None" },
          NormalFloat = { bg = "None" },
          ColorColumn = { bg = "None" },
          SignColumn = { bg = "None" },
          Folded = { bg = "None" },
          FoldColumn = { bg = "None" },
          CursorLine = { bg = "#0F1419" },
          CursorColumn = { bg = "None" },
          VertSplit = { bg = "None" },
          LineNr = { fg = "#5C6773" },
          CursorLineNr = { bg = "#0F1419" },
        },
      })
      require("ayu").colorscheme()
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      local function is_blackish(c)
        if type(c) ~= "string" then
          return false
        end
        local hex = c:gsub("#", "")
        if #hex ~= 6 then
          return false
        end
        local r = tonumber(hex:sub(1, 2), 16) or 0
        local g = tonumber(hex:sub(3, 4), 16) or 0
        local b = tonumber(hex:sub(5, 6), 16) or 0
        return r < 32 and g < 32 and b < 32
      end
      local theme = require("lualine.themes.ayu")
      for _, mode in pairs(theme) do
        for _, section in pairs(mode) do
          if is_blackish(section.bg) then
            section.bg = "#0F1419"
          end
        end
      end
      opts.options = opts.options or {}
      opts.options.theme = theme
    end,
  },
  -- {
  --   "tiagovla/tokyodark.nvim",
  --   lazy = false,
  --   priority = 1000,
  --   opts = {
  --     transparent_background = true,
  --   },
  --   config = function(_, opts)
  --     require("tokyodark").setup(opts) -- calling setup is optional
  --     vim.cmd([[colorscheme tokyodark]])
  --   end,
  -- },
  -- -- {
  -- --   "LazyVim/LazyVim",
  -- --   opts = {
  -- --     -- colorscheme = "monokai-pro",
  -- --     colorscheme = "catppuccin",
  -- --   },
  -- -- },
  {
    "folke/snacks.nvim",
    opts = {
      dashboard = { enabled = false },
    },
  },
  {
    "jackplus-xyz/monaspace.nvim",
    lazy = false,
    use_default = true,
  },
}
