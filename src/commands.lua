require "src/TapeDeck"

local tapedeck

local function ensure_tapedeck()
  if not tapedeck then
    tapedeck = TapeDeck()
  end

  return tapedeck
end

local function maybe_error(err)
  if err then renoise.app():show_error(err) end
end

local function record_sample()
  maybe_error(ensure_tapedeck():record())
end

local function toggle_monitor()
  maybe_error(ensure_tapedeck():toggle_monitor())
end

renoise.tool():add_keybinding {
  name = "Global:TapeDeck:Record New Sample",
  invoke = record_sample
}

renoise.tool():add_keybinding {
  name = "Global:TapeDeck:Toggle Monitor",
  invoke = toggle_monitor
}

renoise.tool():add_menu_entry {
  name = "Main Menu:File:Record New Sample With TapeDeck",
  invoke = record_sample
}

renoise.tool():add_menu_entry {
  name = "DSP Device:Toggle TapeDeck Monitor",
  invoke = toggle_monitor
}

renoise.tool():add_menu_entry {
  name = "Mixer:Toggle TapeDeck Monitor",
  invoke = toggle_monitor
}
