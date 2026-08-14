local t = require("testlib")
local Memory = require("craftos_blink.memory")
local R, W, X = Memory.PROT_READ, Memory.PROT_WRITE, Memory.PROT_EXEC

local m = Memory.new({ max_pages = 4 })
m:map(0x1000, 8192, R + W)
m:write(0x1ffe, "abcd")
t.eq(m:read(0x1ffe, 4), "abcd", "cross-page access")
t.eq(m:read_u32(0x1ffe), 0x64636261, "little endian word")
t.raises(function() m:read8(0x3000) end,
  function(e) return type(e) == "table" and e.code == "SEGV_MAPERR" end)
m:protect(0x2000, 4096, R)
t.raises(function() m:write8(0x2000, 1) end,
  function(e) return type(e) == "table" and e.code == "SEGV_ACCERR" end)
m:protect(0x2000, 4096, R + W)
local child = m:fork()
child:write8(0x1000, 42)
t.eq(child:read8(0x1000), 42, "child private write")
t.eq(m:read8(0x1000), 0, "parent copy unchanged")
m:map(0x3000, 4096, R + W, { shared = true })
local shared = m:fork()
shared:write8(0x3000, 9)
t.eq(m:read8(0x3000), 9, "shared mapping visible")
m:map(0x4000, 4096, R + W + X)
local generation = m.generation
m:write8(0x4000, 0x90)
t.truthy(m.generation > generation, "executable write invalidates decode cache")
t.raises(function() m:map(0x5000, 4096, R) end,
  function(e) return type(e) == "table" and e.class == "resource_limit" end)

