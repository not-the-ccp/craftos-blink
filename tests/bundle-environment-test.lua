-- CC:Tweaked injects require into each program environment, but its BIOS
-- global environment does not contain require. Ensure preloaded module chunks
-- inherit the program environment instead of Lua's global environment.
local host_require = require
local output = {}
local program_environment = setmetatable({
  arg = { "--help" },
  io = false,
  package = package,
  require = host_require,
  printError = function(value) output[#output + 1] = tostring(value) end,
}, { __index = _G })

local chunk = assert(loadfile("build/test-craftos-blink.lua", "t", program_environment))
_G.require = nil
local ok, result = pcall(chunk)
_G.require = host_require

assert(ok, result)
assert(result == 0, "bundled CLI --help returned " .. tostring(result))
assert(table.concat(output):find("usage: craftos%-blink"), "bundled CLI did not print usage")
io.write("[PASS] bundled CLI in CC:Tweaked-style environment\n")
