local t = require("testlib")
local Memory = require("craftos_blink.memory")
local decoder = require("craftos_blink.decoder")
local R, W, X = Memory.PROT_READ, Memory.PROT_WRITE, Memory.PROT_EXEC

local m = Memory.new()
m:map(0x1000, 4096, R + W + X)
m:write(0x1000, "\72\139\68\136\16") -- mov rax,[rax+rcx*4+16]
local r = decoder.reader(m, 0x1000)
r:prefixes64(); t.eq(r:u8(), 0x8b)
local mr = r:modrm()
t.eq(mr.reg, 0); t.eq(mr.operand.base, 0); t.eq(mr.operand.index, 1)
t.eq(mr.operand.scale, 4); t.eq(mr.operand.disp, 16); t.eq(r.pos, 0x1005)

m:write(0x1010, "\76\139\5\52\18\0\0") -- mov r8,[rip+0x1234]
r = decoder.reader(m, 0x1010); r:prefixes64(); r:u8(); mr = r:modrm()
t.eq(mr.reg, 8); t.truthy(mr.operand.rip_relative); t.eq(mr.operand.disp, 0x1234)

m:write(0x1020, "\136\228\64\136\228") -- mov ah,ah; mov spl,spl
r = decoder.reader(m, 0x1020); r:prefixes64(); r:u8(); mr = r:modrm()
t.truthy(mr.reg_operand.high8); t.truthy(mr.operand.high8)
r = decoder.reader(m, 0x1022); r:prefixes64(); r:u8(); mr = r:modrm()
t.eq(r.rex_present, true); t.eq(mr.reg_operand.high8, nil); t.eq(mr.operand.high8, nil)
