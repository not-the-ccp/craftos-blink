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

