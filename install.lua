-- CraftOS Blink alpha installer for ComputerCraft/CraftOS.
local version = "0.1.0-alpha.2"
local base = "https://github.com/not-the-ccp/craftos-blink/releases/download/v" .. version .. "/"
local target = (arg and arg[1]) or "craftos-blink"

if type(fs) ~= "table" or type(http) ~= "table" then
  error("install.lua must run under ComputerCraft with the HTTP API enabled", 0)
end

local function download(name)
  local response, message = http.get(base .. name, nil, true)
  if not response then error("could not download " .. name .. ": " .. tostring(message), 0) end
  local data = response.readAll()
  response.close()
  return data
end

local function write(path, data)
  local handle = fs.open(path, "wb") or fs.open(path, "w")
  if not handle then error("could not write " .. path, 0) end
  handle.write(data)
  handle.close()
end

fs.makeDir(target)
write(fs.combine(target, "craftos_blink.lua"), download("craftos_blink.lua"))
write(fs.combine(target, "craftos-blink.lua"), download("craftos-blink.lua"))
write(fs.combine(target, "SHA256SUMS"), download("SHA256SUMS"))

print("Installed CraftOS Blink " .. version .. " in /" .. target)
print("Run: " .. fs.combine(target, "craftos-blink.lua") .. " --help")
