local t = require("testlib")
local Memory = require("craftos_blink.memory")
local VFS = require("craftos_blink.vfs")
local CPU = require("craftos_blink.cpu")
local Kernel = require("craftos_blink.kernel")
local u64 = require("craftos_blink.u64")

local memory = Memory.new()
local vfs = VFS.new({ root = "." })
local cpu = CPU.new(memory)
local kernel = Kernel.new(memory, vfs)

-- No-argument syscalls must not inspect unrelated scratch registers.
cpu:set_reg(0, u64.from_number(110), 64)
cpu:set_reg(8, u64.new(0x12345678, 0x87654321), 64)
kernel:dispatch(cpu)
t.eq(u64.to_number(cpu.regs[0]), 0, "getppid")

-- Linux commonly passes MAP_ANONYMOUS with an fd and offset of -1.
cpu:set_reg(0, u64.from_number(9), 64)
cpu:set_reg(7, u64.zero(), 64)
cpu:set_reg(6, u64.from_number(4096), 64)
cpu:set_reg(2, u64.from_number(3), 64)
cpu:set_reg(10, u64.from_number(0x22), 64)
cpu:set_reg(8, u64.from_signed(-1), 64)
cpu:set_reg(9, u64.from_signed(-1), 64)
kernel:dispatch(cpu)
t.eq(u64.to_number(cpu.regs[0]), 0x71000000, "anonymous mmap with signed arguments")

cpu:set_reg(0, u64.from_number(12), 64)
cpu:set_reg(7, u64.from_number(0x70001000), 64)
for _, reg in ipairs({ 6, 2, 10, 8, 9 }) do cpu:set_reg(reg, u64.zero(), 64) end
kernel:dispatch(cpu)
t.eq(u64.to_number(cpu.regs[0]), 0x70001000, "brk grows")
memory:write8(0x70000000, 0x5a)
t.eq(memory:read8(0x70000000), 0x5a, "brk maps writable heap")
