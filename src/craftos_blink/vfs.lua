-- Sandboxed guest filesystem with ComputerCraft and POSIX host adapters.
local M = {}
M.__index = M

local function split(path)
  local result = {}
  for part in path:gmatch("[^/]+") do result[#result + 1] = part end
  return result
end

function M.normalize(path, cwd)
  assert(type(path) == "string" and not path:find("[%z\r\n]"), "invalid guest path")
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
    list = fs.list,
    make_dir = function(path)
      local ok, err = pcall(fs.makeDir, path)
      if not ok then return nil, "EACCES" end
      return fs.isDir(path) and true or nil, err and "EACCES" or "EIO"
    end,
    delete = function(path)
      local ok = pcall(fs.delete, path)
      return ok and true or nil, "EACCES"
    end,
    combine = fs.combine,
  }
end

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function command_line(command)
  local handle = io.popen(command, "r")
  if not handle then return nil end
  local value = handle:read("*l")
  local ok = handle:close()
  return ok and value or nil
end

local function command_output(command)
  local handle = io.popen(command, "r")
  if not handle then return nil end
  local value = handle:read("*a")
  local ok = handle:close()
  return ok and value or nil
end

local function command_ok(command)
  local ok = os.execute(command)
  return ok == true or ok == 0
end

local function posix_adapter(root)
  local canonical_root = command_line("realpath -m -- " .. shell_quote(root))
  assert(canonical_root, "realpath is required by the POSIX sandbox adapter")
  local function resolve(path, allow_missing)
    local option = allow_missing and "-m" or "-e"
    local canonical = command_line("realpath " .. option .. " -- " .. shell_quote(path) .. " 2>/dev/null")
    if not canonical then return nil, "ENOENT" end
    if canonical_root ~= "/" and canonical ~= canonical_root
        and canonical:sub(1, #canonical_root + 1) ~= canonical_root .. "/" then
      return nil, "EACCES"
    end
    return canonical
  end
  return {
    read = function(path)
      local safe, err = resolve(path, false)
      if not safe then return nil, err end
      local h = io.open(safe, "rb")
      if not h then return nil, "ENOENT" end
      local data = h:read("*a"); h:close(); return data
    end,
    write = function(path, data)
      local safe, err = resolve(path, true)
      if not safe then return nil, err end
      local h = io.open(safe, "wb")
      if not h then return nil, "EACCES" end
      h:write(data); h:close(); return true
    end,
    exists = function(path)
      local safe = resolve(path, false)
      if not safe then return false end
      return command_ok("test -e " .. shell_quote(safe))
    end,
    is_dir = function(path)
      local safe = resolve(path, false)
      if not safe then return false end
      return command_line("test -d " .. shell_quote(safe) .. " && printf yes") == "yes"
    end,
    list = function(path)
      local safe, err = resolve(path, false)
      if not safe then return nil, err end
      if not command_ok("test -d " .. shell_quote(safe)) then return nil, "ENOTDIR" end
      local data = command_output("find " .. shell_quote(safe) ..
        " -mindepth 1 -maxdepth 1 -printf '%f\\0'")
      if data == nil then return nil, "EACCES" end
      local names = {}
      for name in data:gmatch("([^%z]+)%z") do names[#names + 1] = name end
      table.sort(names)
      return names
    end,
    make_dir = function(path)
      local safe, err = resolve(path, true)
      if not safe then return nil, err end
      if command_ok("mkdir -- " .. shell_quote(safe)) then return true end
      return nil, command_ok("test -e " .. shell_quote(safe)) and "EEXIST" or "EACCES"
    end,
    delete = function(path)
      local safe, err = resolve(path, false)
      if not safe then return nil, err end
      if command_ok("rm -f -- " .. shell_quote(safe)) then return true end
      return nil, "EACCES"
    end,
    combine = function(a, b) return a:gsub("/$", "") .. "/" .. b:gsub("^/", "") end,
  }
end

function M.new(options)
  options = options or {}
  local adapter = options.adapter or (type(fs) == "table" and fs.open and cc_adapter() or posix_adapter(options.root or "."))
  return setmetatable({ root = options.root or ".", cwd = M.normalize(options.cwd or "/"),
    adapter = adapter, metadata = {}, virtual = {} }, M)
end

local function copy_metadata(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do
    result[copy_metadata(key, seen)] = copy_metadata(item, seen)
  end
  return result
end

-- Forks share the filesystem adapter and immutable virtual-node definitions,
-- but each process owns its path context and per-path metadata. executable is
-- a value snapshot. maps_text is intentionally the same callback; it receives
-- the VFS being read so a process model can derive text from its own state.
function M:clone()
  return setmetatable({
    root = self.root,
    cwd = self.cwd,
    adapter = self.adapter,
    metadata = copy_metadata(self.metadata),
    virtual = self.virtual,
    executable = self.executable,
    maps_text = self.maps_text,
    pid = self.pid,
  }, M)
end

function M:guest_path(path) return M.normalize(path, self.cwd) end

function M:guest_path_from(path, base)
  return M.normalize(path, base or self.cwd)
end

function M:host_path(path)
  local guest = self:guest_path(path)
  return self.adapter.combine(self.root, guest:sub(2)), guest
end

function M:read_file(path)
  local host, guest = self:host_path(path)
  if self.virtual[guest] then return self.virtual[guest]("read", self) end
  local data, err = self.adapter.read(host)
  if not data then return nil, err or "ENOENT" end
  return data
end

function M:stat(path)
  local host, guest = self:host_path(path)
  if self.virtual[guest] then
    local kind = guest:sub(1, 5) == "/dev/" and "device" or "file"
    local data = self.virtual[guest]("read", self) or ""
    return { kind = kind, size = #data, path = guest }
  end
  if not self.adapter.exists(host) then return nil, "ENOENT" end
  if self.adapter.is_dir and self.adapter.is_dir(host) then
    return { kind = "directory", size = 0, path = guest }
  end
  local data, err = self.adapter.read(host)
  if data == nil then return nil, err or "EACCES" end
  return { kind = "file", size = #data, path = guest }
end

function M:list(path)
  local host = self:host_path(path)
  if not self.adapter.list then return nil, "ENOSYS" end
  return self.adapter.list(host)
end

function M:make_dir(path)
  local host, guest = self:host_path(path)
  if self.virtual[guest] then return nil, "EEXIST" end
  if not self.adapter.make_dir then return nil, "ENOSYS" end
  return self.adapter.make_dir(host)
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
  self.pid = pid or 1
  self.virtual["/dev/null"] = function() return "" end
  self.virtual["/dev/zero"] = function() return "" end
  self.virtual["/proc/self/exe"] = function(_, current)
    return current.executable or ""
  end
  self.virtual["/proc/self/maps"] = function(_, current)
    return current.maps_text and current.maps_text(current) or ""
  end
  self.virtual["/proc/self/status"] = function(_, current)
    return "Name:\tcraftos-blink\nPid:\t" .. tostring(current.pid or 1) .. "\nThreads:\t1\n"
  end
end

return M
