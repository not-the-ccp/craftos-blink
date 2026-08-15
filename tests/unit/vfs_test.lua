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

-- A fork gets its own namespace state, while the immutable adapter and virtual
-- node table intentionally remain shared. Nested metadata must not leak from a
-- child into its parent either.
local fork_files = { ["root/work/file"] = "shared backing file" }
local fork_directories = { ["root"] = true, ["root/work"] = true }
local fork_adapter = {
  combine = function(a, b) return a:gsub("/$", "") .. "/" .. b:gsub("^/", "") end,
  read = function(path) return fork_files[path], fork_files[path] and nil or "ENOENT" end,
  write = function(path, data) fork_files[path] = data; return true end,
  exists = function(path) return fork_files[path] ~= nil or fork_directories[path] == true end,
  is_dir = function(path) return fork_directories[path] == true end,
}
local parent = VFS.new({ root = "root", cwd = "/", adapter = fork_adapter })
parent.metadata = { ["/work/file"] = { mode = 420, nested = { owner = "parent" } } }
parent.executable = "/bin/parent"
parent.maps_payload = "parent maps\n"
parent.maps_text = function(current) return current.maps_payload end
parent:install_virtual_nodes(7)
local child = parent:clone()

t.eq(child.adapter, parent.adapter, "fork shares backing adapter")
t.eq(child.root, parent.root, "fork shares immutable root value")
t.eq(child.virtual, parent.virtual, "fork shares immutable virtual handlers")
t.eq(child.maps_text, parent.maps_text, "fork retains dynamic maps callback")
t.truthy(child:chdir("/work"), "child can change cwd")
t.eq(child.cwd, "/work", "child cwd changes")
t.eq(parent.cwd, "/", "child cwd leaves parent unchanged")
child.metadata["/work/file"].nested.owner = "child"
child.metadata["/child-only"] = { mode = 384 }
t.eq(parent.metadata["/work/file"].nested.owner, "parent", "nested metadata is copied")
t.eq(parent.metadata["/child-only"], nil, "metadata entries are independent")
t.eq(child:read_file("file"), "shared backing file", "child sees shared backing files")
child.executable = "/bin/child"
child.maps_payload = "child maps\n"
child.pid = 8
t.eq(parent:read_file("/proc/self/exe"), "/bin/parent", "parent proc exe remains dynamic")
t.eq(child:read_file("/proc/self/exe"), "/bin/child", "child proc exe uses child state")
t.eq(parent:read_file("/proc/self/maps"), "parent maps\n", "parent maps callback gets parent")
t.eq(child:read_file("/proc/self/maps"), "child maps\n", "child maps callback gets child")
t.eq(parent:read_file("/proc/self/status"), "Name:\tcraftos-blink\nPid:\t7\nThreads:\t1\n",
  "parent proc status remains dynamic")
t.eq(child:read_file("/proc/self/status"), "Name:\tcraftos-blink\nPid:\t8\nThreads:\t1\n",
  "child proc status uses child state")

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
t.truthy(host_vfs:make_dir("/directory"), "host adapter creates directory")
t.truthy(host_vfs:write_file("/directory/file", "host data"), "host adapter writes child")
local directory_info = host_vfs:stat("/directory")
t.eq(directory_info.kind, "directory", "host adapter stats directory")
local names = assert(host_vfs:list("/directory"))
t.eq(#names, 1, "host adapter lists one child")
t.eq(names[1], "file", "host adapter lists stable child name")
assert(command_ok("rm -rf -- " .. quoted))
