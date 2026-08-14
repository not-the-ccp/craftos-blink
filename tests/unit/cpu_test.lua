local t = require("testlib")
local Memory = require("craftos_blink.memory")
local CPU = require("craftos_blink.cpu")
local u = require("craftos_blink.u64")
local R, W, X = Memory.PROT_READ, Memory.PROT_WRITE, Memory.PROT_EXEC

local m = Memory.new()
m:map(0x1000, 4096, R + W + X); m:map(0x8000, 4096, R + W)
-- mov rax,5; mov rcx,7; add rax,rcx; cmp rax,12; jne bad; push rax; pop rdx; nop
local code = "\72\184\5\0\0\0\0\0\0\0\72\185\7\0\0\0\0\0\0\0" ..
  "\72\1\200\72\131\248\12\117\4\80\90\144"
m:write(0x1000, code)
local cpu = CPU.new(m, { rip = 0x1000 }); cpu:set_reg(4, u.from_number(0x9000), 64)
for _ = 1, 8 do cpu:step() end
t.eq(u.to_number(cpu.regs[0]), 12, "addition")
t.eq(u.to_number(cpu.regs[2]), 12, "push/pop")
t.eq(cpu.rip, 0x1000 + #code, "conditional branch not taken")

-- RIP-relative load.
m:write(0x1100, "\72\139\5\1\0\0\0\144" .. "\120\86\52\18\0\0\0\0")
cpu.rip = 0x1100; cpu:step()
t.eq(u.hex(cpu.regs[0]), "0000000012345678", "RIP-relative addressing")

local fault = t.raises(function() cpu.rip = 0x1120; m:write8(0x1120, 0xf4); cpu:step() end,
  function(e) return type(e) == "table" and e.signal == "SIGILL" end)
t.eq(fault.address, 0x1120)

