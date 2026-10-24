-- hypr/bindings.lua against a stand-in for Hyprland's Lua API (tools/test-bindings).
local binds, unbound, dispatched, executed = {}, {}, {}, {}
local active = "kitty"
hl = {
  unbind = function(keys) unbound[#unbound + 1] = keys end,
  bind = function(keys, fn, opts) binds[#binds + 1] = { keys = keys, fn = fn, opts = opts or {} } end,
  get_active_window = function() return { class = active } end,
  dispatch = function(d) dispatched[#dispatched + 1] = d end,
  exec_cmd = function(cmd) executed[#executed + 1] = cmd end,
  dsp = { send_key_state = function(t) return t.mods .. "|" .. t.key .. "|" .. t.state end },
}
o = { bind = function(keys, description, fn, opts) assert(description, "described for Omarchy's shortcut menu"); hl.bind(keys, fn, opts) end }
local function fail(msg) io.stderr:write("bindings: FAIL " .. msg .. "\n"); os.exit(1) end
local case = os.getenv("CASE")
dofile(os.getenv("PLUGIN") .. "/hypr/bindings.lua")
if case == "default" then
  if #binds ~= 2 or binds[1].keys ~= "CTRL + SPACE" or unbound[1] ~= "CTRL + SPACE" then fail("Ctrl+Space by default") end
  if binds[1].opts.release or not binds[2].opts.release then fail("press and release") end
  if binds[1].opts.locked or binds[2].opts.locked then fail("never on the lock screen") end
  binds[1].fn(); binds[2].fn()
  if executed[1] ~= "omarchy-shell -q omarchy-dictation press" or executed[2] ~= "omarchy-shell -q omarchy-dictation release" then fail("press/release go to the service") end
  -- Omarchy T3 Code keeps its own Ctrl+Space.
  active = "io.github.avillagran.omarchy-t3-code"; binds[1].fn(); binds[2].fn()
  if dispatched[1] ~= "CTRL|SPACE|down" or dispatched[2] ~= "CTRL|SPACE|up" or #executed ~= 2 then fail("passthrough to T3 Code: " .. tostring(dispatched[1])) end
elseif case == "custom" then
  if binds[1].keys ~= "SUPER + ALT + D" then fail("custom shortcut: " .. tostring(binds[1] and binds[1].keys)) end
  active = "io.github.avillagran.omarchy-t3-code"; binds[1].fn()
  if #dispatched ~= 0 or executed[1] == nil then fail("custom passthrough list replaces the default") end
  active = "code"; binds[1].fn()
  if dispatched[1] ~= "SUPER ALT|D|down" then fail("listed app gets the key with its modifiers") end
elseif case == "disabled" then
  if #binds ~= 0 then fail("disabled binds nothing") end
elseif case == "invalid" then
  if binds[1].keys ~= "CTRL + SPACE" then fail("an invalid shortcut falls back to Ctrl+Space") end
end
print("bindings: PASS " .. case)
