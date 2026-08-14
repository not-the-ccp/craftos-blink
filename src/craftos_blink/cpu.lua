local u64 = require("craftos_blink.u64")
local decoder = require("craftos_blink.decoder")
local flags = require("craftos_blink.flags")

local M = {}
M.__index = M
M.register_names = { "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
  "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" }

local function guest_fault(cpu, signal, code)
  error({ class = "guest_fault", signal = signal, code = code, address = cpu.rip }, 0)
end

function M.new(memory, options)
  options = options or {}
  local regs = {}
  for i = 0, 15 do regs[i] = u64.zero() end
  return setmetatable({ memory = memory, regs = regs, rip = options.rip or 0,
    rflags = 2, fs_base = 0, gs_base = 0, instructions = 0,
    syscall = options.syscall, trace = options.trace, halted = false }, M)
end

function M:get_reg(index, bits)
  local v = self.regs[index]
  if bits == 64 then return u64.clone(v) end
  if bits == 32 then return u64.new(v[1], 0) end
  if bits == 16 then return u64.new(bit32.band(v[1], 0xffff), 0) end
  return u64.new(bit32.band(v[1], 0xff), 0)
end

function M:set_reg(index, value, bits)
  bits = bits or 64
  if bits == 64 then self.regs[index] = u64.clone(value)
  elseif bits == 32 then self.regs[index] = u64.new(value[1], 0)
  elseif bits == 16 then
    self.regs[index] = u64.new(bit32.bor(bit32.band(self.regs[index][1], 0xffff0000),
      bit32.band(value[1], 0xffff)), self.regs[index][2])
  else
    self.regs[index] = u64.new(bit32.bor(bit32.band(self.regs[index][1], 0xffffff00),
      bit32.band(value[1], 0xff)), self.regs[index][2])
  end
end

function M:address(op, next_rip)
  local address = op.disp or 0
  if op.rip_relative then address = address + next_rip end
  if op.base then address = address + u64.to_number(self.regs[op.base]) end
  if op.index then address = address + u64.to_number(self.regs[op.index]) * op.scale end
  if address < 0 then address = address + 9007199254740992 end
  assert(address >= 0 and address < 9007199254740992, "non-canonical guest address")
  return address
end

function M:read_operand(op, bits, next_rip)
  if op.kind == "reg" then return self:get_reg(op.reg, bits) end
  local address = self:address(op, next_rip)
  if bits == 8 then return u64.new(self.memory:read8(address), 0)
  elseif bits == 16 then return u64.new(self.memory:read_u16(address), 0)
  elseif bits == 32 then return u64.new(self.memory:read_u32(address), 0)
  else return self.memory:read_u64(address) end
end

function M:write_operand(op, value, bits, next_rip)
  if op.kind == "reg" then return self:set_reg(op.reg, value, bits) end
  local address = self:address(op, next_rip)
  if bits == 8 then self.memory:write8(address, value[1])
  elseif bits == 16 then self.memory:write_u16(address, value[1])
  elseif bits == 32 then self.memory:write_u32(address, value[1])
  else self.memory:write_u64(address, value) end
end

local function mask(value, bits)
  if bits == 64 then return value end
  if bits == 32 then return u64.new(value[1], 0) end
  return u64.new(bit32.band(value[1], 2 ^ bits - 1), 0)
end

local function sign(value, bits) return u64.bit(value, bits - 1) ~= 0 end

function M:set_arithmetic_flags(kind, a, b, result, bits)
  a, b, result = mask(a, bits), mask(b, bits), mask(result, bits)
  local f = flags.logic(result, bits)
  local carry, overflow
  if kind == "add" then
    carry = u64.cmp(result, a) < 0
    overflow = sign(a, bits) == sign(b, bits) and sign(result, bits) ~= sign(a, bits)
  else
    carry = u64.cmp(a, b) < 0
    overflow = sign(a, bits) ~= sign(b, bits) and sign(result, bits) ~= sign(a, bits)
  end
  if carry then f = bit32.bor(f, flags.CF) end
  if overflow then f = bit32.bor(f, flags.OF) end
  if bit32.band(bit32.bxor(bit32.bxor(a[1], b[1]), result[1]), 0x10) ~= 0 then
    f = bit32.bor(f, flags.AF)
  end
  self.rflags = bit32.bor(f, 2)
end

function M:binary(kind, destination, source, bits, next_rip, write)
  local a = self:read_operand(destination, bits, next_rip)
  local b = source.kind and self:read_operand(source, bits, next_rip) or source
  local result
  if kind == "add" then result = u64.add(a, b); self:set_arithmetic_flags("add", a, b, result, bits)
  elseif kind == "sub" or kind == "cmp" then
    result = u64.sub(a, b); self:set_arithmetic_flags("sub", a, b, result, bits)
  elseif kind == "and" or kind == "test" then result = u64.band(a, b); self.rflags = bit32.bor(flags.logic(mask(result, bits), bits), 2)
  elseif kind == "or" then result = u64.bor(a, b); self.rflags = bit32.bor(flags.logic(mask(result, bits), bits), 2)
  elseif kind == "xor" then result = u64.bxor(a, b); self.rflags = bit32.bor(flags.logic(mask(result, bits), bits), 2)
  end
  if write ~= false and kind ~= "cmp" and kind ~= "test" then self:write_operand(destination, mask(result, bits), bits, next_rip) end
end

function M:push(value)
  self.regs[4] = u64.sub(self.regs[4], u64.from_number(8))
  self.memory:write_u64(u64.to_number(self.regs[4]), value)
end

function M:pop()
  local value = self.memory:read_u64(u64.to_number(self.regs[4]))
  self.regs[4] = u64.add32(self.regs[4], 8)
  return value
end

local group_kinds = { [0] = "add", [1] = "or", [4] = "and", [5] = "sub", [6] = "xor", [7] = "cmp" }

function M:step()
  local start = self.rip
  local r = decoder.reader(self.memory, start)
  r:prefixes64()
  local op = r:u8()
  local bits = decoder.operand_bits(r, false)
  local mnemonic = "?"

  if op >= 0x50 and op <= 0x57 then
    local reg = op - 0x50 + (bit32.band(r.rex, 1) ~= 0 and 8 or 0)
    self:push(self:get_reg(reg, 64)); mnemonic = "push"
  elseif op >= 0x58 and op <= 0x5f then
    local reg = op - 0x58 + (bit32.band(r.rex, 1) ~= 0 and 8 or 0)
    self:set_reg(reg, self:pop(), 64); mnemonic = "pop"
  elseif op >= 0xb8 and op <= 0xbf then
    local reg = op - 0xb8 + (bit32.band(r.rex, 1) ~= 0 and 8 or 0)
    if bits == 64 then self:set_reg(reg, u64.new(r:u32(), r:u32()), 64)
    else self:set_reg(reg, u64.new(bits == 16 and r:u16() or r:u32(), 0), bits) end
    mnemonic = "mov"
  elseif op == 0x68 or op == 0x6a then
    local imm = op == 0x68 and r:i32() or r:i8()
    self:push(u64.from_signed(imm)); mnemonic = "push"
  elseif op == 0x90 then mnemonic = "nop"
  elseif op == 0xc3 then r.pos = u64.to_number(self:pop()); mnemonic = "ret"
  elseif op == 0xc9 then self.regs[4] = u64.clone(self.regs[5]); self.regs[5] = self:pop(); mnemonic = "leave"
  elseif op == 0xe8 then
    local disp = r:i32(); self:push(u64.from_number(r.pos)); r.pos = r.pos + disp; mnemonic = "call"
  elseif op == 0xe9 then local d = r:i32(); r.pos = r.pos + d; mnemonic = "jmp"
  elseif op == 0xeb then local d = r:i8(); r.pos = r.pos + d; mnemonic = "jmp"
  elseif op >= 0x70 and op <= 0x7f then
    local d = r:i8(); if flags.condition(op - 0x70, self.rflags) then r.pos = r.pos + d end; mnemonic = "jcc"
  elseif op == 0x88 or op == 0x89 or op == 0x8a or op == 0x8b then
    local mr = r:modrm(); local width = (op == 0x88 or op == 0x8a) and 8 or bits
    local regop = { kind = "reg", reg = mr.reg }
    local dst, src = (op == 0x88 or op == 0x89) and mr.operand or regop,
      (op == 0x88 or op == 0x89) and regop or mr.operand
    local value = self:read_operand(src, width, r.pos)
    self:write_operand(dst, value, width, r.pos); mnemonic = "mov"
  elseif op == 0x8d then
    local mr = r:modrm(); if mr.operand.kind ~= "mem" then guest_fault(self, "SIGILL", "ILL_ILLOPN") end
    self:set_reg(mr.reg, u64.from_number(self:address(mr.operand, r.pos)), bits); mnemonic = "lea"
  elseif op == 0x63 then
    local mr = r:modrm(); local v = self:read_operand(mr.operand, 32, r.pos)
    self:set_reg(mr.reg, u64.sign_extend(v, 32), bit32.band(r.rex, 8) ~= 0 and 64 or 32); mnemonic = "movsxd"
  elseif op == 0x01 or op == 0x03 or op == 0x09 or op == 0x0b or op == 0x21 or op == 0x23
      or op == 0x29 or op == 0x2b or op == 0x31 or op == 0x33 or op == 0x39 or op == 0x3b or op == 0x85 then
    local mr = r:modrm(); local regop = { kind = "reg", reg = mr.reg }
    local reverse = op == 0x03 or op == 0x0b or op == 0x23 or op == 0x2b or op == 0x33 or op == 0x3b
    local dst, src = reverse and regop or mr.operand, reverse and mr.operand or regop
    local kind = (op == 0x01 or op == 0x03) and "add" or (op == 0x09 or op == 0x0b) and "or"
      or (op == 0x21 or op == 0x23) and "and" or (op == 0x29 or op == 0x2b) and "sub"
      or (op == 0x31 or op == 0x33) and "xor" or (op == 0x39 or op == 0x3b) and "cmp" or "test"
    self:binary(kind, dst, src, bits, r.pos); mnemonic = kind
  elseif op == 0x81 or op == 0x83 then
    local mr = r:modrm(); local kind = group_kinds[mr.opcode]
    if not kind then guest_fault(self, "SIGILL", "ILL_ILLOPN") end
    local imm = op == 0x83 and r:i8() or (bits == 16 and r:u16() or r:i32())
    self:binary(kind, mr.operand, u64.from_signed(imm), bits, r.pos); mnemonic = kind
  elseif op == 0xc6 or op == 0xc7 then
    local mr = r:modrm(); if mr.opcode ~= 0 then guest_fault(self, "SIGILL", "ILL_ILLOPN") end
    local width = op == 0xc6 and 8 or bits
    local value = width == 8 and u64.new(r:u8(), 0) or width == 16 and u64.new(r:u16(), 0)
      or u64.sign_extend(u64.new(r:u32(), 0), 32)
    self:write_operand(mr.operand, value, width, r.pos); mnemonic = "mov"
  elseif op == 0x0f then
    local op2 = r:u8()
    if op2 == 0x05 then
      if not self.syscall then guest_fault(self, "SIGSYS", "SYS_SECCOMP") end
      self.syscall(self); mnemonic = "syscall"
    elseif op2 == 0xa2 then
      local leaf = self.regs[0][1]
      if leaf == 0 then
        self:set_reg(0, u64.new(1, 0), 32)
        self:set_reg(1, u64.new(0x66617243, 0), 32) -- "Craf"
        self:set_reg(3, u64.new(0x6c422074, 0), 32) -- "t Bl"
        self:set_reg(2, u64.new(0x206b6e69, 0), 32) -- "ink "
      else
        self:set_reg(0, u64.new(0x00000663, 0), 32)
        self:set_reg(1, u64.zero(), 32); self:set_reg(2, u64.new(1, 0), 32); self:set_reg(3, u64.zero(), 32)
      end
      mnemonic = "cpuid"
    elseif op2 >= 0x80 and op2 <= 0x8f then
      local d = r:i32(); if flags.condition(op2 - 0x80, self.rflags) then r.pos = r.pos + d end; mnemonic = "jcc"
    elseif op2 == 0xb6 or op2 == 0xb7 or op2 == 0xbe or op2 == 0xbf then
      local mr = r:modrm(); local srcbits = (op2 == 0xb6 or op2 == 0xbe) and 8 or 16
      local v = self:read_operand(mr.operand, srcbits, r.pos)
      if op2 == 0xbe or op2 == 0xbf then v = u64.sign_extend(v, srcbits) end
      self:set_reg(mr.reg, v, bits); mnemonic = (op2 == 0xbe or op2 == 0xbf) and "movsx" or "movzx"
    elseif op2 == 0x1e and r.prefixes.rep then
      local modrm = r:u8(); if modrm ~= 0xfa then guest_fault(self, "SIGILL", "ILL_ILLOPN") end; mnemonic = "endbr64"
    elseif op2 == 0x1f then r:modrm(); mnemonic = "nop"
    else guest_fault(self, "SIGILL", "ILL_ILLOPN") end
  else
    guest_fault(self, "SIGILL", "ILL_ILLOPN")
  end

  self.rip, self.instructions = r.pos, self.instructions + 1
  if self.trace then self.trace({ rip = start, next_rip = self.rip, mnemonic = mnemonic }) end
  return mnemonic
end

function M:run(limit, should_yield)
  limit = limit or math.huge
  local count = 0
  while not self.halted and count < limit do
    self:step(); count = count + 1
    if should_yield and should_yield(self, count) then return "yield" end
  end
  return self.halted and "halted" or "limit"
end

return M

