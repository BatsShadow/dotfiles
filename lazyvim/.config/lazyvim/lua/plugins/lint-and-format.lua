local auto_format = vim.g.lazyvim_eslint_auto_format == nil or vim.g.lazyvim_eslint_auto_format

return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        jsonls = {},
        eslint = {
          settings = {
            -- helps eslint find the eslintrc when it's placed in a subfolder instead of the cwd root
            workingDirectories = { mode = "auto" },
            format = auto_format,
          },
        },
        stylelint_lsp = {},
        vtsls = {
          settings = {
            typescript = {
              inlayHints = {
                enumMemberValues = { enabled = false },
                functionLikeReturnTypes = { enabled = false },
                parameterNames = { enabled = false },
                parameterTypes = { enabled = false },
                propertyDeclarationTypes = { enabled = false },
                variableTypes = { enabled = false },
              },
            },
          },
        },
      },
      setup = {
        inlay_hints = { enabled = false },

        stylelint_lsp = function(_, opts)
          opts.filetypes = { "css", "scss", "less", "sass" }
          opts.settings = {
            stylelintplus = {
              autoFixOnFormat = true,
              autoFixOnSave = true,
            },
          }
        end,

        eslint = function(_, opts)
          opts.filetypes = {
            "html",
            "htmlangular",
            "javascript",
            "javascriptreact",
            "javascript.jsx",
            "typescript",
            "typescriptreact",
            "typescript.tsx",
            "vue",
            "svelte",
            "astro",
          }

          local formatter = LazyVim.lsp.formatter({
            name = "eslint: lsp",
            primary = false,
            priority = 200,
            filter = "eslint",
          })

          require("lazyvim.util").lsp.on_attach(function(client)
            if client.name == "eslint" then
              client.server_capabilities.documentFormattingProvider = true
            elseif client.name == "tsserver" then
              client.server_capabilities.documentFormattingProvider = false
            elseif client.name == "vtsls" then
              client.server_capabilities.documentFormattingProvider = false
            elseif client.name == "jsonls" then
              client.server_capabilities.documentFormattingProvider = false
            end
          end)

          LazyVim.format.register(formatter)
        end,
      },
    },
  },
}
