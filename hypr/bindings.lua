-- Omarchy Dictation: the shortcut (Ctrl+Space unless changed in the bar's
-- microphone panel). Loaded from ~/.config/hypr/bindings.lua by install.sh;
-- the panel reloads Hyprland when the shortcut changes. Hold to talk, or tap to
-- start and tap again. Not locked: nothing is dictated on the lock screen.
local config = os.getenv("XDG_CONFIG_HOME")
if not config or config:sub(1, 1) ~= "/" then config = os.getenv("HOME") .. "/.config" end
local file = io.open(config .. "/omarchy-dictation/settings.json", "r")
local settings = file and file:read(16384) or ""
if file then file:close() end

if not settings:match('"enabled"%s*:%s*false') then
  local shortcut = settings:match('"shortcut"%s*:%s*"([A-Z0-9_ +]+)"') or "CTRL + SPACE"
  local parts = {}
  for part in shortcut:gmatch("[^ +]+") do parts[#parts + 1] = part end
  local key = table.remove(parts)
  local valid = key and #parts <= 4 and #shortcut <= 64
  for _, mod in ipairs(parts) do
    valid = valid and (mod == "SUPER" or mod == "CTRL" or mod == "ALT" or mod == "SHIFT")
  end
  if not valid then shortcut, parts, key = "CTRL + SPACE", { "CTRL" }, "SPACE" end
  local mods = table.concat(parts, " ")

  -- Apps with their own dictation on this key get it instead (Omarchy T3 Code's composer).
  local passthrough = {}
  local list = settings:match('"passthrough"%s*:%s*(%b[])')
  if list then
    for class in list:gmatch('"([^"]+)"') do passthrough[class] = true end
  else
    passthrough["io.github.avillagran.omarchy-t3-code"] = true
  end
  local function passes()
    local window = hl.get_active_window()
    return window ~= nil and passthrough[window.class] == true
  end
  local function handle(method, state)
    return function()
      if passes() then
        hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = state }))
      else
        hl.exec_cmd("omarchy-shell -q omarchy-dictation " .. method)
      end
    end
  end

  hl.unbind(shortcut)
  o.bind(shortcut, "Dictate: hold to talk, or tap to start and stop", handle("press", "down"))
  o.bind(shortcut, "Dictate: release to insert", handle("release", "up"), { release = true })
end
