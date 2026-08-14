-- Sandboxed guest filesystem with ComputerCraft and POSIX host adapters.
local M = {}
M.__index = M

local function split(path)
  local result = {}
  for part in path:gmatch("[^/]+") do result[#result + 1] = part end
  return result
end

function M.normalize(path, cwd)
  assert(type(path) == "string" and not path:find("%z"), "invalid guest path")
  local parts = {}
  if path:sub(1, 1) ~= "/" then
    for _, part in ipairs(split(cwd or "/")) do parts[#parts + 1] = part end
  end
  for _, part in ipairs(split(path)) do
    if part == ".." then
      if #parts == 0 then
        error({ class = "sandbox_violation", path = path }, 0)
      end
      parts[#parts] = nil
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/")
end

local function cc_adapter()
  return {
    read = function(path)
      local h = fs.open(path, "rb") or fs.open(path, "r")
      if not h then return nil, "ENOENT" end
      local data = h.readAll(); h.close(); return data
    end,
    write = function(path, data)
      local h = fs.open(path, "wb") or fs.open(path, "w")
      if not h then return nil, "EACCES" end
      h.write(data); h.close(); return true
    end,
    exists = fs.exists,
    is_dir = fs.isDir,
    make_dir = fs.makeDir,
    delete = fs.delete,
    combine = fs.combine,
  }
end

local function posix_adapter()
  return {
    read = function(path)
      local h = io.open(path, "rb")
      if not h then return nil, "ENOENT" end
      local data = h:read("*a"); h:close(); return data
    end,
    write = function(path, data)
      local h = io.open(path, "wb")
      if not h then return nil, "EACCES" end
      h:write(data); h:close(); return true
    end,
    exists = function(path) local h = io.open(path, "rb"); if h then h:close(); return true end; return false end,
    combine = function(a, b) return a:gsub("/$", "") .. "/" .. b:gsub("^/", "") end,
  }
end

function M.new(options)
  options = options or {}
  local adapter = options.adapter or (type(fs) == "table" and fs.open and cc_adapter() or posix_adapter())
  return setmetatable({ root = options.root or ".", cwd = M.normalize(options.cwd or "/"),
    adapter = adapter, metadata = {}, virtual = {} }, M)
end

function M:guest_path(path) return M.normalize(path, self.cwd) end

function M:host_path(path)
  local guest = self:guest_path(path)
  return self.adapter.combine(self.root, guest:sub(2)), guest
end

function M:read_file(path)
  local host, guest = self:host_path(path)
  if self.virtual[guest] then return self.virtual[guest]("read") end
  local data, err = self.adapter.read(host)
  if not data then return nil, err or "ENOENT" end
  return data
end

function M:write_file(path, data)
  local host, guest = self:host_path(path)
  if self.virtual[guest] then return nil, "EPERM" end
  return self.adapter.write(host, data)
end

function M:exists(path)
  local host, guest = self:host_path(path)
  return self.virtual[guest] ~= nil or self.adapter.exists(host)
end

function M:chdir(path)
  local normalized = self:guest_path(path)
  local host = self.adapter.combine(self.root, normalized:sub(2))
  if self.adapter.is_dir and not self.adapter.is_dir(host) then return nil, "ENOTDIR" end
  self.cwd = normalized
  return true
end

function M:install_virtual_nodes(pid)
  self.virtual["/dev/null"] = function() return "" end
  self.virtual["/dev/zero"] = function() return "" end
  self.virtual["/proc/self/exe"] = function() return self.executable or "" end
  self.virtual["/proc/self/maps"] = function() return self.maps_text and self.maps_text() or "" end
  self.virtual["/proc/self/status"] = function()
    return "Name:\tcraftos-blink\nPid:\t" .. tostring(pid or 1) .. "\nThreads:\t1\n"
  end
end

return M

