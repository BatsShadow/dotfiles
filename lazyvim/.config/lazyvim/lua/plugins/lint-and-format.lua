return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      inlay_hints = { enabled = false },
      servers = {
        jsonls = {},

        -- Linter (live diagnostics, fix-all on save)
        oxlint = {},

        -- Formatter (LSP-based; replaces what eslint+prettier used to do)
        oxfmt = {},

        -- Kept only for Angular HTML templates; angular-eslint covers what
        -- oxlint cannot. Not a formatter anymore — oxfmt handles that.
        eslint = {
          settings = {
            workingDirectories = { mode = "auto" },
            format = false,
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
          -- Keep the broad filetype set so non-oxlint projects still get
          -- eslint diagnostics. In upngo, eslint-plugin-oxlint silences
          -- rules oxlint already covers, so there's no duplication.
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

          Snacks.util.lsp.on({ name = "eslint" }, function(_, client)
            client.server_capabilities.documentFormattingProvider = false
          end)
        end,

        oxfmt = function(_, opts)
          local formatter = LazyVim.lsp.formatter({
            name = "oxfmt: lsp",
            primary = true,
            priority = 200,
            filter = "oxfmt",
          })

          -- Make oxfmt the canonical formatter; suppress everyone else who
          -- might claim formatting for JS/TS/JSON.
          Snacks.util.lsp.on({ name = "oxfmt" }, function(_, client)
            client.server_capabilities.documentFormattingProvider = true
          end)
          for _, name in ipairs({ "tsserver", "vtsls", "jsonls", "eslint" }) do
            Snacks.util.lsp.on({ name = name }, function(_, client)
              client.server_capabilities.documentFormattingProvider = false
            end)
          end

          LazyVim.format.register(formatter)
        end,

        oxlint = function(_, _)
          -- Apply oxlint autofixes on save. LazyVim's format-on-save runs
          -- first (registered earlier in startup), then this handler runs
          -- :LspOxlintFixAll — matches the VS Code source.format.oxc ->
          -- source.fixAll.oxc ordering.
          local group = vim.api.nvim_create_augroup("user_oxlint_fix_on_save", { clear = true })
          vim.api.nvim_create_autocmd("LspAttach", {
            group = group,
            callback = function(args)
              local client = vim.lsp.get_client_by_id(args.data.client_id)
              if not client or client.name ~= "oxlint" then
                return
              end
              vim.api.nvim_create_autocmd("BufWritePre", {
                group = group,
                buffer = args.buf,
                command = "LspOxlintFixAll",
              })
            end,
          })
        end,
      },
    },
  },
}
