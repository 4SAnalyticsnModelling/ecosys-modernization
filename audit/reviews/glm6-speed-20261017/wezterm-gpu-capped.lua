local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.color_scheme = 'Tokyo Night Moon'
config.font = wezterm.font 'FiraCode Nerd Font Mono'
config.font_size = 24.0
config.window_background_opacity = 0.9

-- Use macOS Metal GPU acceleration with automatic adapter selection.
config.front_end = 'WebGpu'
config.webgpu_power_preference = 'HighPerformance'

-- Preserve modified keys for Pi and other terminal applications.
config.enable_kitty_keyboard = true
config.keys = {
  {
    key = 'Enter',
    mods = 'ALT',
    action = wezterm.action.SendString('\x1b[13;3u'),
  },
}

-- Load the existing Oh My Zsh configuration and prompt.
config.default_prog = { '/bin/zsh', '-l' }

config.launch_menu = {
  {
    label = 'Herdr',
    args = { '/opt/homebrew/bin/herdr' },
  },
}

-- Limit terminal redraw overhead while local GLM inference is running.
config.max_fps = 30
config.animation_fps = 10

return config
