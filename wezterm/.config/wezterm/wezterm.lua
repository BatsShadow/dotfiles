-- Pull in the wezterm API
local wezterm = require('wezterm')

-- local mux = wezterm.mux

-- Equivalent to POSIX basename(3)
-- Given "/foo/bar" returns "bar"
-- Given "c:\\foo\\bar" returns "bar"
local function basename(s)
  return string.gsub(s, '(.*[/\\])(.*)', '%2')
end

---@diagnostic disable-next-line: undefined-global
NVIM_SPECIAL_LEADER = utf8.char(0xff)

-- local function create_nvim_key_bind(key, mods, code)
--   return {
--     key = key,
--     mods = mods,
--     action = wezterm.action_callback(function(win, pane)
--       -- local proc = basename(pane:get_foreground_process_name())
--       -- if proc ~= "nvim" then
--       --   win:perform_action(
--       --     wezterm.action.SendKey({
--       --       key = key,
--       --       mods = mods,
--       --     }),
--       --     pane
--       --   )
--       --   return
--       -- end
--
--       local key_code = NVIM_SPECIAL_LEADER .. code
--
--       win:perform_action(wezterm.action.SendString(key_code), pane)
--     end),
--   }
-- end

-- This will hold the configuration.
local config = wezterm.config_builder()

config.window_close_confirmation = 'NeverPrompt'

-- Send leader-<num> to switch tmux windows
local create_tab_action = function(key)
  return wezterm.action_callback(function(win, pane)
    local proc = basename(pane:get_foreground_process_name())
    if proc ~= 'tmux' then
      return
    end
    win:perform_action(
      wezterm.action.Multiple({
        wezterm.action.SendKey({ key = ' ', mods = 'CTRL' }),
        wezterm.action.SendKey({ key = key }),
      }),
      pane
    )
  end)
end

local cmd_window = function(window)
  return {
    key = window,
    mods = 'CMD',
    action = create_tab_action(window),
  }
end

-- config.debug_key_events = true
config.keys = {
  -- Rebind OPT-Left, OPT-Right as ALT-b, ALT-f respectively to match Terminal.app behavior
  {
    key = 'LeftArrow',
    mods = 'OPT',
    action = wezterm.action.SendKey({
      key = 'b',
      mods = 'ALT',
    }),
  },
  {
    key = 'RightArrow',
    mods = 'OPT',
    action = wezterm.action.SendKey({ key = 'f', mods = 'ALT' }),
  },
  {
    key = 'LeftArrow',
    mods = 'CMD',
    action = wezterm.action.SendKey({ key = 'a', mods = 'CTRL' }),
  },
  {
    key = 'RightArrow',
    mods = 'CMD',
    action = wezterm.action.SendKey({ key = 'e', mods = 'CTRL' }),
  },
  -- Bind cmd-K to clear screen
  {
    key = 'k',
    mods = 'CMD',
    action = wezterm.action_callback(function(win, pane)
      local proc = basename(pane:get_foreground_process_name())
      if proc ~= 'tmux' then
        win:perform_action(wezterm.action.ClearScrollback('ScrollbackAndViewport'), pane)
        return
      end

      win:perform_action(
        wezterm.action.Multiple({
          wezterm.action.SendKey({ key = ' ', mods = 'CTRL' }),
          wezterm.action.SendKey({ key = 'k', mods = 'CTRL' }),
        }),
        pane
      )
    end),
  },
  -- Bind cmd-T to tumx Create Window (no more Wezterm tabs)
  {
    key = 't',
    mods = 'CMD',
    action = wezterm.action_callback(function(win, pane)
      local proc = basename(pane:get_foreground_process_name())
      if proc ~= 'tmux' then
        return
      end

      win:perform_action(
        wezterm.action.Multiple({
          wezterm.action.SendKey({ key = ' ', mods = 'CTRL' }),
          wezterm.action.SendKey({ key = 'c' }),
        }),
        pane
      )
    end),
  },
  -- Bind cmd-NUM to switch tmux windows
  cmd_window('1'),
  cmd_window('2'),
  cmd_window('3'),
  cmd_window('4'),
  cmd_window('5'),
  cmd_window('6'),
  cmd_window('7'),
  cmd_window('8'),
  cmd_window('9'),
  cmd_window('0'),
  -- Shift+Enter sends newline for Claude Code
  {
    key = 'Enter',
    mods = 'SHIFT',
    action = wezterm.action.SendString('\x1b[13;2u'),
  },
}

-- For example, changing the color scheme:
-- config.color_scheme = "3024 (dark) (terminal.sexy)"
-- config.color_scheme = 'catppuccin-mocha'
config.color_scheme = 'ayu'

config.initial_rows = 60
config.initial_cols = 176

-- Monaspace superfamily: a different style for each intensity/italic combination
-- Neon (neo-grotesque) / Xenon (slab serif) / Argon (humanist sans) / Krypton (mechanical)
local roman_features = { 'calt', 'liga' }
local italic_features = { 'calt', 'liga', 'ss01' }

config.font = wezterm.font_with_fallback({
  { family = 'Monaspace Neon', harfbuzz_features = roman_features },
  { family = 'SF Pro', scale = 1.0 },
  { family = 'Symbols Nerd Font Mono' },
})

config.font_rules = {
  {
    intensity = 'Normal',
    italic = false,
    font = wezterm.font({
      family = 'Monaspace Neon',
      weight = 'Medium',
      harfbuzz_features = roman_features,
    }),
  },
  {
    intensity = 'Bold',
    italic = false,
    font = wezterm.font({
      family = 'Monaspace Xenon',
      weight = 'Black',
      harfbuzz_features = roman_features,
    }),
  },
  {
    intensity = 'Normal',
    italic = true,
    font = wezterm.font({
      family = 'Monaspace Argon',
      weight = 'Light',
      style = 'Italic',
      harfbuzz_features = italic_features,
    }),
  },
  {
    intensity = 'Bold',
    italic = true,
    font = wezterm.font({
      family = 'Monaspace Krypton',
      weight = 'Medium',
      harfbuzz_features = italic_features,
    }),
  },
}

config.font_size = 15
config.line_height = 1.2

config.window_background_opacity = 0.9
config.macos_window_background_blur = 30
config.window_decorations = 'INTEGRATED_BUTTONS|RESIZE'
config.use_fancy_tab_bar = false
config.integrated_title_button_style = 'Windows'
config.hide_tab_bar_if_only_one_tab = true

config.window_padding = {
  left = 16,
  right = 16,
  top = 8,
  bottom = 0,
}

config.colors = {
  background = '#151720',
  tab_bar = {
    -- The color of the strip that goes along the top of the window
    -- (does not apply when fancy tab bar is in use)
    background = '#000',

    -- The active tab is the one that has focus in the window
    active_tab = {
      bg_color = '#000',
      fg_color = '#fff',
      -- "Half", "Normal" or "Bold" intensity for the
      intensity = 'Normal',
      -- "None", "Single" or "Double" underline for
      underline = 'Single',
    },

    -- Inactive tabs are the tabs that do not have focus
    inactive_tab = {
      bg_color = '#000',
      fg_color = '#fff',
      intensity = 'Half',

      -- The same options that were listed under the `active_tab` section above
      -- can also be used for `inactive_tab`.
    },

    -- You can configure some alternate styling when the mouse pointer
    -- moves over inactive tabs
    inactive_tab_hover = {
      bg_color = '#222',
      fg_color = '#fff',
    },

    -- The new tab button that let you create new tabs
    new_tab = {
      bg_color = '#000',
      fg_color = '#000',
    },

    -- You can configure some alternate styling when the mouse pointer
    -- moves over the new tab button
    new_tab_hover = {
      bg_color = '#444',
      fg_color = '#aaa',
    },
  },
}

return config
