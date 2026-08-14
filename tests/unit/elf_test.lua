local t = require("testlib")
local ELF = require("craftos_blink.elf")

t.raises(function() ELF.parse("not elf") end,
  function(e) return type(e) == "table" and e.class == "malformed_elf" and e.code == "truncated_header" end)
t.raises(function() ELF.parse(string.rep("\0", 64)) end,
  function(e) return type(e) == "table" and e.code == "bad_magic" end)

local h = assert(io.open("build/fixtures/hello", "rb"))
local data = h:read("*a"); h:close()
local elf = ELF.parse(data)
t.eq(elf.machine, 62)
t.eq(elf.type, 2)
t.truthy(#elf.program_headers > 0)
t.truthy(elf.entry > 0)

-- Load the host's PIE executable and its requested glibc interpreter without
-- executing either. This verifies ET_DYN relocation and PT_INTERP mapping.
local Memory = require("craftos_blink.memory")
local VFS = require("craftos_blink.vfs")
local memory = Memory.new()
local loaded = ELF.load(memory, VFS.new({ root = "/" }), "/bin/true", {
  argv = { "/bin/true" }, env = { "LANG=C" }, stack_size = 65536,
})
t.truthy(loaded.base ~= 0, "PIE base")
t.truthy(loaded.interp and loaded.interp:match("ld%-linux"), "PT_INTERP")
t.truthy(loaded.interp_base ~= 0, "interpreter base")
t.eq(memory:read_u64(loaded.stack)[1], 1, "argc on System V stack")

-- Shebang recursion reuses the normal ELF loader while preserving the script
-- path for the interpreter argv.
local files = { ["root/script"] = "#!/bin/interpreter -x\necho ignored\n" }
local fixture = assert(io.open("build/fixtures/hello", "rb")); files["root/bin/interpreter"] = fixture:read("*a"); fixture:close()
local adapter = {
  combine = function(a, b) return a .. "/" .. b end,
  read = function(path) return files[path], files[path] and nil or "ENOENT" end,
  write = function() return nil, "EROFS" end,
  exists = function(path) return files[path] ~= nil end,
}
local script_memory = Memory.new()
local script = ELF.load(script_memory, VFS.new({ root = "root", adapter = adapter }), "/script", {
  argv = { "/script", "arg" }, env = {}, stack_size = 65536,
})
t.eq(script.script, "/script")
t.eq(script.script_interpreter, "/bin/interpreter")

