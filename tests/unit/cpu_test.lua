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

-- rep stosq
m:write(0x1140, "\243\72\171")
cpu.rip = 0x1140
cpu:set_reg(0, u.new(0x55667788, 0x11223344), 64)
cpu:set_reg(1, u.from_number(3), 64)
cpu:set_reg(7, u.from_number(0x8100), 64)
cpu:step()
t.eq(u.hex(m:read_u64(0x8100)), "1122334455667788", "rep stos first value")
t.eq(u.hex(m:read_u64(0x8110)), "1122334455667788", "rep stos last value")
t.eq(u.to_number(cpu.regs[1]), 0, "rep stos count")
t.eq(u.to_number(cpu.regs[7]), 0x8118, "rep stos destination")

-- cmp rax, rdx; cmovb rax, rdx
m:write(0x1160, "\72\57\208\72\15\66\194")
cpu.rip = 0x1160
cpu:set_reg(0, u.from_number(10), 64)
cpu:set_reg(2, u.from_number(20), 64)
cpu:step(); cpu:step()
t.eq(u.to_number(cpu.regs[0]), 20, "conditional move")

-- cmp ebx, imm32; sete sil; test al, sil
m:write(0x1180, "\129\251\32\32\83\104\64\15\148\198\64\132\198")
cpu.rip = 0x1180
cpu:set_reg(3, u.from_number(0x68532020), 32)
cpu:set_reg(0, u.from_number(1), 32)
cpu:step(); cpu:step(); cpu:step()
t.eq(u.to_number(cpu:get_reg(6, 8)), 1, "setcc byte register")
t.truthy(bit32.band(cpu.rflags, require("craftos_blink.flags").ZF) == 0, "byte test flags")

-- and eax, imm32
m:write(0x11a0, "\37\16\129\136\23")
cpu.rip = 0x11a0
cpu:set_reg(0, u.from_number(0xffffffff), 32)
cpu:step()
t.eq(u.to_number(cpu.regs[0]), 0x17888110, "accumulator immediate")

-- test ebp, imm32; not eax
m:write(0x11c0, "\247\197\0\8\0\0\247\208")
cpu.rip = 0x11c0
cpu:set_reg(5, u.from_number(0x800), 32)
cpu:set_reg(0, u.from_number(0), 32)
cpu:step(); cpu:step()
t.truthy(bit32.band(cpu.rflags, require("craftos_blink.flags").ZF) == 0, "group test flags")
t.eq(u.to_number(cpu.regs[0]), 0xffffffff, "group not")

-- movq rax,xmm0; punpcklqdq xmm0,xmm0; movaps xmm0,(rsp)
m:write(0x11e0, "\102\72\15\110\192\102\15\108\192\15\41\4\36")
cpu.rip = 0x11e0
cpu:set_reg(0, u.new(0x55667788, 0x11223344), 64)
cpu:set_reg(4, u.from_number(0x8200), 64)
cpu:step(); cpu:step(); cpu:step()
t.eq(u.hex(m:read_u64(0x8200)), "1122334455667788", "SSE low quadword")
t.eq(u.hex(m:read_u64(0x8208)), "1122334455667788", "SSE unpacked quadword")

-- shr rcx,3; rep movsq
m:write(0x1200, "\72\193\233\3\243\72\165")
m:write_u64(0x8240, u.new(0x89abcdef, 0x01234567))
cpu.rip = 0x1200
cpu:set_reg(1, u.from_number(8), 64)
cpu:set_reg(6, u.from_number(0x8240), 64)
cpu:set_reg(7, u.from_number(0x8260), 64)
cpu:step(); cpu:step()
t.eq(u.to_number(cpu.regs[1]), 0, "rep movs count")
t.eq(u.hex(m:read_u64(0x8260)), "0123456789abcdef", "rep movsq value")

-- mov fs:0,rax
m:write(0x1220, "\100\72\139\4\37\0\0\0\0")
m:write_u64(0x8280, u.new(0xaabbccdd, 0x11223344))
cpu.rip = 0x1220
cpu.fs_base = 0x8280
cpu:step()
t.eq(u.hex(cpu.regs[0]), "11223344aabbccdd", "FS-relative addressing")

-- cdqe; cqo
m:write(0x1240, "\72\152\72\153")
cpu.rip = 0x1240
cpu:set_reg(0, u.new(0xfffffffe, 0), 64)
cpu:step(); cpu:step()
t.eq(u.hex(cpu.regs[0]), "fffffffffffffffe", "cdqe sign extension")
t.eq(u.hex(cpu.regs[2]), "ffffffffffffffff", "cqo sign extension")

-- div ecx: edx:eax / ecx -> eax remainder edx
m:write(0x1260, "\247\241")
cpu.rip = 0x1260
cpu:set_reg(0, u.from_number(79), 32)
cpu:set_reg(2, u.zero(), 32)
cpu:set_reg(1, u.from_number(39), 32)
cpu:step()
t.eq(u.to_number(cpu.regs[0]), 2, "unsigned division quotient")
t.eq(u.to_number(cpu.regs[2]), 1, "unsigned division remainder")

-- imul r8,rdi
m:write(0x1280, "\76\15\175\199")
cpu.rip = 0x1280
cpu:set_reg(8, u.from_number(7), 64)
cpu:set_reg(7, u.from_number(9), 64)
cpu:step()
t.eq(u.to_number(cpu.regs[8]), 63, "two-operand signed multiply")

-- pxor xmm0,xmm0
m:write(0x12a0, "\102\15\239\192")
cpu.rip = 0x12a0
cpu.xmm[0] = { 1, 2, 3, 4 }
cpu:step()
t.eq(cpu.xmm[0][1] + cpu.xmm[0][2] + cpu.xmm[0][3] + cpu.xmm[0][4], 0, "packed xor")

-- movdqu unaligned source
m:write(0x12c0, "\243\15\111\2")
m:write_u32(0x82c1, 0x12345678)
cpu.rip = 0x12c0
cpu:set_reg(2, u.from_number(0x82c1), 64)
cpu:step()
t.eq(cpu.xmm[0][1], 0x12345678, "unaligned packed move")

-- imul rsi,rcx,58
m:write(0x12e0, "\72\107\241\58")
cpu.rip = 0x12e0
cpu:set_reg(1, u.from_number(3), 64)
cpu:step()
t.eq(u.to_number(cpu.regs[6]), 174, "three-operand signed multiply")

local fault = t.raises(function() cpu.rip = 0x1120; m:write8(0x1120, 0xf4); cpu:step() end,
  function(e) return type(e) == "table" and e.signal == "SIGILL" end)
t.eq(fault.address, 0x1120)
