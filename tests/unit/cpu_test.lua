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

-- cmp establishes carry; adc edi,0
m:write(0x1300, "\72\57\200\131\215\0")
cpu.rip = 0x1300
cpu:set_reg(0, u.from_number(3), 64)
cpu:set_reg(1, u.from_number(4), 64)
cpu:set_reg(7, u.from_number(8), 32)
cpu:step(); cpu:step()
t.eq(u.to_number(cpu.regs[7]), 9, "add with carry")

-- mov byte [rsi+rcx],0 with a negative index
m:write(0x1320, "\198\4\14\0")
cpu.rip = 0x1320
cpu:set_reg(6, u.from_number(0x8300), 64)
cpu:set_reg(1, u.from_signed(-4), 64)
cpu:step()
t.eq(m:read8(0x82fc), 0, "signed address index")

-- lea is integer arithmetic and may produce any 64-bit bit pattern.
m:write(0x1340, "\74\141\12\2")
cpu.rip = 0x1340
cpu:set_reg(2, u.new(0x01020304, 0x11121314), 64)
cpu:set_reg(8, u.new(0xfefefeff, 0xfefefefe), 64)
cpu:step()
t.eq(u.hex(cpu.regs[1]), u.hex(u.add(u.new(0x01020304, 0x11121314),
  u.new(0xfefefeff, 0xfefefefe))), "64-bit LEA arithmetic")

-- pshufd xmm0,xmm0,0 broadcasts the low lane.
m:write(0x1360, "\102\15\112\192\0")
cpu.rip = 0x1360
cpu.xmm[0] = { 0x2020202, 2, 3, 4 }
cpu:step()
t.eq(cpu.xmm[0][4], 0x2020202, "packed dword shuffle")

-- bt rcx,rdx
m:write(0x1380, "\72\15\163\209")
cpu.rip = 0x1380
cpu:set_reg(1, u.from_number(0x20), 64)
cpu:set_reg(2, u.from_number(5), 64)
cpu:step()
t.truthy(bit32.band(cpu.rflags, require("craftos_blink.flags").CF) ~= 0, "bit test carry")

-- bt ebx,10
m:write(0x13a0, "\15\186\227\10")
cpu.rip = 0x13a0
cpu:set_reg(3, u.from_number(0x400), 32)
cpu:step()
t.truthy(bit32.band(cpu.rflags, require("craftos_blink.flags").CF) ~= 0, "immediate bit test")

-- pushfq/pop r11 exposes the architectural flags word.
m:write(0x13c0, "\156\65\91")
cpu.rip = 0x13c0
cpu.rflags = 0x895
cpu:step(); cpu:step()
t.eq(cpu.regs[11][1], 0x895, "push flags")

-- Legacy high-byte registers exist only when no REX prefix is present.
m:write(0x13e0, "\180\18\64\180\52")
cpu.rip = 0x13e0
cpu:set_reg(0, u.from_number(0x55660000), 64)
cpu:set_reg(4, u.from_number(0x8800), 64)
cpu:step(); cpu:step()
t.eq(cpu.regs[0][1], 0x55661200, "mov ah immediate")
t.eq(bit32.band(cpu.regs[4][1], 0xff), 0x34, "REX mov spl immediate")

-- Operand-width rotates wrap within the selected register width.
m:write(0x1400, "\209\192")
cpu.rip = 0x1400
cpu:set_reg(0, u.from_number(0x80000000), 32)
cpu:step()
t.eq(cpu.regs[0][1], 1, "32-bit rotate left")

-- Arithmetic status updates preserve direction, interrupt, and trap flags.
m:write(0x1420, "\72\131\192\1")
cpu.rip = 0x1420
cpu.rflags = bit32.bor(2, 0x100, 0x200, 0x400)
cpu:step()
t.eq(bit32.band(cpu.rflags, 0x700), 0x700, "control flags survive arithmetic")

-- Full-width multiply and 128-bit dividend division.
m:write(0x1440, "\72\247\225\72\247\241")
cpu.rip = 0x1440
cpu:set_reg(0, u.new(0xffffffff, 0xffffffff), 64)
cpu:set_reg(1, u.from_number(2), 64)
cpu:step()
t.eq(u.hex(cpu.regs[0]), "fffffffffffffffe", "64-bit multiply low")
t.eq(u.hex(cpu.regs[2]), "0000000000000001", "64-bit multiply high")
cpu:set_reg(0, u.zero(), 64)
cpu:set_reg(2, u.one(), 64)
cpu:step()
t.eq(u.hex(cpu.regs[0]), "8000000000000000", "128-by-64 division quotient")
t.eq(u.hex(cpu.regs[2]), "0000000000000000", "128-by-64 division remainder")

local lock_fault = t.raises(function()
  cpu.rip = 0x1460; m:write(0x1460, "\240\144"); cpu:step()
end, function(e) return type(e) == "table" and e.signal == "SIGILL" end)
t.eq(lock_fault.code, "ILL_ILLOPN", "LOCK rejected until atomic semantics exist")

m:write(0x1480, "\240\131\4\36\0") -- lock addl $0,(rsp)
cpu.rip = 0x1480
cpu:set_reg(4, u.from_number(0x8400), 64)
m:write_u32(0x8400, 0x12345678)
cpu:step()
t.eq(m:read_u32(0x8400), 0x12345678, "valid LOCKed memory RMW")

-- movdqu stores do not require 16-byte alignment.
m:write(0x1500, "\243\15\127\2")
cpu.rip = 0x1500
cpu:set_reg(2, u.from_number(0x8501), 64)
cpu.xmm[0] = { 0x11223344, 0x55667788, 0x99aabbcc, 0xddeeff00 }
cpu:step()
t.eq(m:read_u32(0x8501), 0x11223344, "movdqu unaligned store low lane")
t.eq(m:read_u32(0x850d), 0xddeeff00, "movdqu unaligned store high lane")

-- Packed SSE2 operations preserve lane order and leave integer flags alone.
m:write(0x1520, "\15\18\193\102\15\212\193\102\15\235\193\102\15\251\193\102\15\98\193\102\15\115\216\5\15\87\193\243\144")
cpu.rip = 0x1520
cpu.rflags = 0x6d7
cpu.xmm[0], cpu.xmm[1] = { 10, 20, 30, 40 }, { 1, 2, 3, 4 }
cpu:step()
t.eq(cpu.xmm[0][1], 3, "movhlps low qword from source high qword")
t.eq(cpu.xmm[0][4], 40, "movhlps keeps destination high qword")
cpu.xmm[0], cpu.xmm[1] = { 0xffffffff, 0, 0xffffffff, 0xffffffff }, { 1, 0, 2, 0 }
cpu:step()
t.eq(cpu.xmm[0][1], 0, "paddq low lane carry")
t.eq(cpu.xmm[0][2], 1, "paddq low lane high word")
t.eq(cpu.xmm[0][3], 1, "paddq high lane carry")
cpu.xmm[0], cpu.xmm[1] = { 0x00ff0000, 0xf0000000, 0, 0x80000000 }, { 0xff0000ff, 0x0f000000, 1, 0x7fffffff }
cpu:step()
t.eq(cpu.xmm[0][1], 0xffff00ff, "por low word")
t.eq(cpu.xmm[0][2], 0xff000000, "por high word")
cpu.xmm[0], cpu.xmm[1] = { 0, 2, 0, 0 }, { 1, 0, 1, 0 }
cpu:step()
t.eq(cpu.xmm[0][1], 0xffffffff, "psubq borrows within low qword")
t.eq(cpu.xmm[0][2], 1, "psubq low qword result")
t.eq(cpu.xmm[0][3], 0xffffffff, "psubq high qword result")
cpu.xmm[0], cpu.xmm[1] = { 10, 20, 30, 40 }, { 1, 2, 3, 4 }
cpu:step()
t.eq(cpu.xmm[0][1], 10, "punpckldq first destination lane")
t.eq(cpu.xmm[0][2], 1, "punpckldq first source lane")
t.eq(cpu.xmm[0][3], 20, "punpckldq second destination lane")
t.eq(cpu.xmm[0][4], 2, "punpckldq second source lane")
cpu.xmm[0] = { 0x04030201, 0x08070605, 0x0c0b0a09, 0x100f0e0d }
cpu:step()
t.eq(cpu.xmm[0][1], 0x09080706, "psrldq shifts across dword lanes")
t.eq(cpu.xmm[0][4], 0, "psrldq zero-fills the high end")
cpu.xmm[0], cpu.xmm[1] = { 0xffffffff, 0, 0xaaaaaaaa, 0x55555555 }, { 0x0f0f0f0f, 0xffffffff, 0x55555555, 0xaaaaaaaa }
cpu:step()
t.eq(cpu.xmm[0][1], 0xf0f0f0f0, "xorps low lane")
t.eq(cpu.xmm[0][4], 0xffffffff, "xorps high lane")
t.eq(cpu:step(), "pause", "pause has no architectural state change")
t.eq(cpu.rflags, 0x6d7, "packed SSE2 operations preserve flags")

m:write(0x1560, "\102\15\115\216\16")
cpu.rip = 0x1560
cpu.xmm[0] = { 1, 2, 3, 4 }
cpu:step()
t.eq(cpu.xmm[0][1] + cpu.xmm[0][2] + cpu.xmm[0][3] + cpu.xmm[0][4], 0,
  "psrldq count at least 16 clears the destination")

-- MOVAPS and MOVDQA require an aligned memory operand; MOVDQU above does not.
local function expect_alignment_fault(bytes, address, label)
  m:write(0x1580, bytes)
  cpu.rip = 0x1580
  cpu:set_reg(2, u.from_number(address), 64)
  local alignment_fault = t.raises(function() cpu:step() end,
    function(e) return type(e) == "table" and e.signal == "SIGSEGV" and e.code == "SEGV_ACCERR" end)
  t.eq(alignment_fault.address, 0x1580, label)
end
expect_alignment_fault("\15\40\2", 0x8501, "movaps load alignment fault")
expect_alignment_fault("\15\41\2", 0x8501, "movaps store alignment fault")
expect_alignment_fault("\102\15\111\2", 0x8501, "movdqa load alignment fault")
expect_alignment_fault("\102\15\127\2", 0x8501, "movdqa store alignment fault")

local fault = t.raises(function() cpu.rip = 0x1120; m:write8(0x1120, 0xf4); cpu:step() end,
  function(e) return type(e) == "table" and e.signal == "SIGILL" end)
t.eq(fault.address, 0x1120)
