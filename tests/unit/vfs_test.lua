local t = require("testlib")
local VFS = require("craftos_blink.vfs")

t.eq(VFS.normalize("a/./b/../c", "/work"), "/work/a/c")
t.eq(VFS.normalize("/usr//bin"), "/usr/bin")
t.raises(function() VFS.normalize("../../escape", "/") end,
  function(e) return type(e) == "table" and e.class == "sandbox_violation" end)
t.raises(function() VFS.normalize("bad\0name", "/") end)
t.raises(function() VFS.normalize("bad\nname", "/") end)

local files = { ["sandbox/file"] = "contents" }
local adapter = {
  combine = function(a, b) return a .. "/" .. b end,
  read = function(path) return files[path], files[path] and nil or "ENOENT" end,
  write = function(path, data) files[path] = data; return true end,
  exists = function(path) return files[path] ~= nil end,
}
local vfs = VFS.new({ root = "sandbox", adapter = adapter })
t.eq(vfs:read_file("/file"), "contents")
t.truthy(vfs:write_file("/new", "new data"))
t.eq(files["sandbox/new"], "new data")

local temporary = os.tmpname()
os.remove(temporary)
local quoted = "'" .. temporary:gsub("'", "'\\''") .. "'"
local function command_ok(command)
  local result = os.execute(command)
  return result == true or result == 0
end
assert(command_ok("mkdir -p " .. quoted))
assert(command_ok("ln -s /etc/passwd " .. quoted .. "/escape"))
local host_vfs = VFS.new({ root = temporary })
local escaped, escape_error = host_vfs:read_file("/escape")
t.eq(escaped, nil, "host symlink escape rejected")
t.eq(escape_error, "EACCES", "host symlink escape errno")
assert(command_ok("rm -rf -- " .. quoted))
