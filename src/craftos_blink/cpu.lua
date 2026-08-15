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
  local regs, xmm = {}, {}
  for i = 0, 15 do regs[i], xmm[i] = u64.zero(), { 0, 0, 0, 0 } end
  return setmetatable({ memory = memory, regs = regs, xmm = xmm, rip = options.rip or 0,
    rflags = 2, fs_base = 0, gs_base = 0, instructions = 0,
    syscall = options.syscall, trace = options.trace, halted = false }, M)
end

function M:read_xmm_operand(op, next_rip)
  if op.kind == "reg" then
    local value = self.xmm[op.reg]
    return { value[1], value[2], value[3], value[4] }
  end
  local address = self:address(op, next_rip)
  return { self.memory:read_u32(address), self.memory:read_u32(address + 4),
    self.memory:read_u32(address + 8), self.memory:read_u32(address + 12) }
end

function M:write_xmm_operand(op, value, next_rip)
  if op.kind == "reg" then
    self.xmm[op.reg] = { value[1], value[2], value[3], value[4] }
    return
  end
  local address = self:address(op, next_rip)
  for i = 1, 4 do self.memory:write_u32(address + (i - 1) * 4, value[i]) end
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

function M:effective_address(op, next_rip)
  local value = u64.from_signed(op.disp or 0)
  if op.rip_relative then value = u64.add(value, u64.from_number(next_rip)) end
  if op.base then value = u64.add(value, self.regs[op.base]) end
  if op.index then
    local shift = op.scale == 8 and 3 or op.scale == 4 and 2 or op.scale == 2 and 1 or 0
    value = u64.add(value, u64.shl(self.regs[op.index], shift))
  end
  return value
end

function M:address(op, next_rip)
  local value = self:effective_address(op, next_rip)
  if op.segment == 0x64 then value = u64.add(value, u64.from_number(self.fs_base))
  elseif op.segment == 0x65 then value = u64.add(value, u64.from_number(self.gs_base)) end
  if value[2] >= 0x00200000 then guest_fault(self, "SIGSEGV", "SEGV_MAPERR") end
  return u64.to_number(value)
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

local function signed_multiply_overflow(left, right, bits)
  local left_negative, right_negative = left[2] >= 0x80000000, right[2] >= 0x80000000
  local left_magnitude = left_negative and u64.neg(left) or left
  local right_magnitude = right_negative and u64.neg(right) or right
  local negative_result = left_negative ~= right_negative
  local limit
  if bits == 64 then limit = negative_result and u64.new(0, 0x80000000) or u64.new(0xffffffff, 0x7fffffff)
  else limit = u64.from_number(negative_result and 2 ^ (bits - 1) or 2 ^ (bits - 1) - 1) end
  if u64.is_zero(right_magnitude) then return false end
  local threshold = u64.divmod(limit, right_magnitude)
  return u64.cmp(left_magnitude, threshold) > 0
end

function M:set_multiply_flags(overflow)
  self.rflags = bit32.bor(bit32.band(self.rflags, bit32.bnot(bit32.bor(flags.CF, flags.OF))), 2)
  if overflow then self.rflags = bit32.bor(self.rflags, flags.CF, flags.OF) end
end

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
  elseif kind == "adc" or kind == "sbb" then
    a, b = mask(a, bits), mask(b, bits)
    local carry_in = bit32.band(self.rflags, flags.CF) ~= 0
    result = kind == "adc" and u64.add(u64.add(a, b), carry_in and u64.one() or u64.zero())
      or u64.sub(u64.sub(a, b), carry_in and u64.one() or u64.zero())
    result = mask(result, bits)
    local carry = kind == "adc" and (u64.cmp(result, a) < 0 or (carry_in and u64.eq(result, a)))
      or (u64.cmp(a, b) < 0 or (carry_in and u64.eq(a, b)))
    local overflow = kind == "adc" and (sign(a, bits) == sign(b, bits) and sign(result, bits) ~= sign(a, bits))
      or kind == "sbb" and (sign(a, bits) ~= sign(b, bits) and sign(result, bits) ~= sign(a, bits))
    local f = flags.logic(result, bits)
    if carry then f = bit32.bor(f, flags.CF) end
    if overflow then f = bit32.bor(f, flags.OF) end
    if bit32.band(bit32.bxor(bit32.bxor(a[1], b[1]), result[1]), 0x10) ~= 0 then
      f = bit32.bor(f, flags.AF)
    end
    self.rflags = bit32.bor(f, 2)
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

local group_kinds = { [0] = "add", [1] = "or", [2] = "adc", [3] = "sbb",
  [4] = "and", [5] = "sub", [6] = "xor", [7] = "cmp" }

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
  elseif op == 0x69 or op == 0x6b then
    local mr = r:modrm()
    local immediate = op == 0x6b and r:i8() or bits == 16 and r:u16() or r:i32()
    local left = u64.sign_extend(self:read_operand(mr.operand, bits, r.pos), bits)
    local right = u64.sign_extend(u64.from_signed(immediate), bits)
    local result_value = u64.mul(left, right)
    self:set_reg(mr.reg, mask(result_value, bits), bits)
    self:set_multiply_flags(signed_multiply_overflow(left, right, bits))
    mnemonic = "imul"
  elseif op == 0x04 or op == 0x05 or op == 0x0c or op == 0x0d or op == 0x14 or op == 0x15
      or op == 0x1c or op == 0x1d or op == 0x24 or op == 0x25
      or op == 0x2c or op == 0x2d or op == 0x34 or op == 0x35 or op == 0x3c or op == 0x3d
      or op == 0xa8 or op == 0xa9 then
    local width = bit32.band(op, 1) == 0 and 8 or bits
    local imm = width == 8 and r:u8() or width == 16 and r:u16() or r:i32()
    local kind = (op == 0x04 or op == 0x05) and "add"
      or (op == 0x0c or op == 0x0d) and "or"
      or (op == 0x14 or op == 0x15) and "adc"
      or (op == 0x1c or op == 0x1d) and "sbb"
      or (op == 0x24 or op == 0x25) and "and"
      or (op == 0x2c or op == 0x2d) and "sub"
      or (op == 0x34 or op == 0x35) and "xor"
      or (op == 0x3c or op == 0x3d) and "cmp" or "test"
    self:binary(kind, { kind = "reg", reg = 0 }, u64.from_signed(imm), width, r.pos)
    mnemonic = kind
  elseif op == 0x90 then mnemonic = "nop"
  elseif op == 0x98 then
    if bits == 16 then self:set_reg(0, u64.sign_extend(self:get_reg(0, 8), 8), 16); mnemonic = "cbw"
    elseif bits == 32 then self:set_reg(0, u64.sign_extend(self:get_reg(0, 16), 16), 32); mnemonic = "cwde"
    else self:set_reg(0, u64.sign_extend(self:get_reg(0, 32), 32), 64); mnemonic = "cdqe" end
  elseif op == 0x99 then
    local negative = u64.bit(self:get_reg(0, bits), bits - 1) ~= 0
    local extension = negative and mask(u64.new(0xffffffff, 0xffffffff), bits) or u64.zero()
    self:set_reg(2, extension, bits)
    mnemonic = bits == 16 and "cwd" or bits == 32 and "cdq" or "cqo"
  elseif op == 0xfc then self.rflags = bit32.band(self.rflags, bit32.bnot(flags.DF)); mnemonic = "cld"
  elseif op == 0xfd then self.rflags = bit32.bor(self.rflags, flags.DF); mnemonic = "std"
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
    self:set_reg(mr.reg, self:effective_address(mr.operand, r.pos), bits); mnemonic = "lea"
  elseif op == 0x63 then
    local mr = r:modrm(); local v = self:read_operand(mr.operand, 32, r.pos)
    self:set_reg(mr.reg, u64.sign_extend(v, 32), bit32.band(r.rex, 8) ~= 0 and 64 or 32); mnemonic = "movsxd"
  elseif op == 0x00 or op == 0x02 or op == 0x08 or op == 0x0a
      or op == 0x10 or op == 0x11 or op == 0x12 or op == 0x13
      or op == 0x18 or op == 0x19 or op == 0x1a or op == 0x1b or op == 0x20 or op == 0x22
      or op == 0x28 or op == 0x2a or op == 0x30 or op == 0x32 or op == 0x38 or op == 0x3a or op == 0x84
      or op == 0x01 or op == 0x03 or op == 0x09 or op == 0x0b or op == 0x21 or op == 0x23
      or op == 0x29 or op == 0x2b or op == 0x31 or op == 0x33 or op == 0x39 or op == 0x3b or op == 0x85 then
    local mr = r:modrm(); local regop = { kind = "reg", reg = mr.reg }
    local reverse = op == 0x02 or op == 0x0a or op == 0x12 or op == 0x13 or op == 0x1a or op == 0x1b
      or op == 0x22 or op == 0x2a or op == 0x32 or op == 0x3a
      or op == 0x03 or op == 0x0b or op == 0x23 or op == 0x2b or op == 0x33 or op == 0x3b
    local dst, src = reverse and regop or mr.operand, reverse and mr.operand or regop
    local kind = (op == 0x00 or op == 0x02 or op == 0x01 or op == 0x03) and "add"
      or (op == 0x08 or op == 0x0a or op == 0x09 or op == 0x0b) and "or"
      or (op == 0x10 or op == 0x12 or op == 0x11 or op == 0x13) and "adc"
      or (op == 0x18 or op == 0x1a or op == 0x19 or op == 0x1b) and "sbb"
      or (op == 0x20 or op == 0x22 or op == 0x21 or op == 0x23) and "and"
      or (op == 0x28 or op == 0x2a or op == 0x29 or op == 0x2b) and "sub"
      or (op == 0x30 or op == 0x32 or op == 0x31 or op == 0x33) and "xor"
      or (op == 0x38 or op == 0x3a or op == 0x39 or op == 0x3b) and "cmp" or "test"
    local width = (op == 0x84 or (bit32.band(op, 1) == 0 and op ~= 0x85)) and 8 or bits
    self:binary(kind, dst, src, width, r.pos); mnemonic = kind
  elseif op == 0x80 or op == 0x81 or op == 0x83 then
    local mr = r:modrm(); local kind = group_kinds[mr.opcode]
    if not kind then guest_fault(self, "SIGILL", "ILL_ILLOPN") end
    local width = op == 0x80 and 8 or bits
    local imm = (op == 0x80 and r:u8()) or (op == 0x83 and r:i8()) or (bits == 16 and r:u16() or r:i32())
    self:binary(kind, mr.operand, u64.from_signed(imm), width, r.pos); mnemonic = kind
  elseif op == 0xc6 or op == 0xc7 then
    local mr = r:modrm(); if mr.opcode ~= 0 then guest_fault(self, "SIGILL", "ILL_ILLOPN") end
    local width = op == 0xc6 and 8 or bits
    local value = width == 8 and u64.new(r:u8(), 0) or width == 16 and u64.new(r:u16(), 0)
      or u64.sign_extend(u64.new(r:u32(), 0), 32)
    self:write_operand(mr.operand, value, width, r.pos); mnemonic = "mov"
  elseif op == 0xc0 or op == 0xc1 or op == 0xd0 or op == 0xd1 or op == 0xd2 or op == 0xd3 then
    local mr = r:modrm()
    local width = (op == 0xc0 or op == 0xd0 or op == 0xd2) and 8 or bits
    local count = (op == 0xc0 or op == 0xc1) and r:u8()
      or (op == 0xd0 or op == 0xd1) and 1 or bit32.band(self.regs[1][1], 0xff)
    count = count % (width == 64 and 64 or 32)
    if count ~= 0 then
      local value = mask(self:read_operand(mr.operand, width, r.pos), width)
      local result_value, carry, overflow
      if mr.opcode == 0 then
        result_value = mask(u64.rol(value, count % width), width)
        carry = u64.bit(result_value, 0) ~= 0
        overflow = count == 1 and (sign(result_value, width) ~= carry)
        mnemonic = "rol"
      elseif mr.opcode == 1 then
        result_value = mask(u64.ror(value, count % width), width)
        carry = u64.bit(result_value, width - 1) ~= 0
        overflow = count == 1 and (sign(result_value, width) ~= (u64.bit(result_value, width - 2) ~= 0))
        mnemonic = "ror"
      elseif mr.opcode == 4 then
        result_value = mask(u64.shl(value, count), width)
        carry = count <= width and u64.bit(value, width - count) ~= 0
        overflow = count == 1 and (sign(result_value, width) ~= carry)
        mnemonic = "shl"
      elseif mr.opcode == 5 then
        result_value = mask(u64.shr(value, count), width)
        carry = count <= width and u64.bit(value, count - 1) ~= 0
        overflow = count == 1 and sign(value, width)
        mnemonic = "shr"
      elseif mr.opcode == 7 then
        result_value = mask(u64.sar(u64.sign_extend(value, width), count), width)
        carry = count <= width and u64.bit(value, count - 1) ~= 0
        overflow = false
        mnemonic = "sar"
      else guest_fault(self, "SIGILL", "ILL_ILLOPN") end
      local new_flags = flags.logic(result_value, width)
      if carry then new_flags = bit32.bor(new_flags, flags.CF) end
      if overflow then new_flags = bit32.bor(new_flags, flags.OF) end
      self.rflags = bit32.bor(new_flags, 2)
      self:write_operand(mr.operand, result_value, width, r.pos)
    else mnemonic = "shift" end
  elseif op == 0xff then
    local mr = r:modrm()
    if mr.opcode == 0 or mr.opcode == 1 then
      local value = self:read_operand(mr.operand, bits, r.pos)
      local carry = bit32.band(self.rflags, flags.CF)
      local one = u64.one()
      local result_value = mr.opcode == 0 and u64.add(value, one) or u64.sub(value, one)
      self:set_arithmetic_flags(mr.opcode == 0 and "add" or "sub", value, one, result_value, bits)
      self.rflags = bit32.bor(bit32.band(self.rflags, bit32.bnot(flags.CF)), carry)
      self:write_operand(mr.operand, mask(result_value, bits), bits, r.pos)
      mnemonic = mr.opcode == 0 and "inc" or "dec"
    elseif mr.opcode == 2 then
      local target = u64.to_number(self:read_operand(mr.operand, 64, r.pos))
      self:push(u64.from_number(r.pos)); r.pos = target; mnemonic = "call"
    elseif mr.opcode == 4 then
      r.pos = u64.to_number(self:read_operand(mr.operand, 64, r.pos)); mnemonic = "jmp"
    elseif mr.opcode == 6 then
      self:push(self:read_operand(mr.operand, 64, r.pos)); mnemonic = "push"
    else guest_fault(self, "SIGILL", "ILL_ILLOPN") end
  elseif op == 0xa4 or op == 0xa5 then
    local width = op == 0xa4 and 8 or bits
    local count = r.prefixes.rep and u64.to_number(self.regs[1]) or 1
    local source, destination, increment = u64.to_number(self.regs[6]), u64.to_number(self.regs[7]), width / 8
    if bit32.band(self.rflags, flags.DF) ~= 0 then increment = -increment end
    for _ = 1, count do
      local value
      if width == 8 then value = u64.new(self.memory:read8(source), 0)
      elseif width == 16 then value = u64.new(self.memory:read_u16(source), 0)
      elseif width == 32 then value = u64.new(self.memory:read_u32(source), 0)
      else value = self.memory:read_u64(source) end
      if width == 8 then self.memory:write8(destination, value[1])
      elseif width == 16 then self.memory:write_u16(destination, value[1])
      elseif width == 32 then self.memory:write_u32(destination, value[1])
      else self.memory:write_u64(destination, value) end
      source, destination = source + increment, destination + increment
    end
    self.regs[6], self.regs[7] = u64.from_number(source), u64.from_number(destination)
    if r.prefixes.rep then self.regs[1] = u64.zero() end
    mnemonic = "movs"
  elseif op == 0xaa or op == 0xab then
    local width = op == 0xaa and 8 or bits
    local count = r.prefixes.rep and u64.to_number(self.regs[1]) or 1
    local address, increment = u64.to_number(self.regs[7]), width / 8
    if bit32.band(self.rflags, flags.DF) ~= 0 then increment = -increment end
    local value = self:get_reg(0, width)
    for _ = 1, count do
      if width == 8 then self.memory:write8(address, value[1])
      elseif width == 16 then self.memory:write_u16(address, value[1])
      elseif width == 32 then self.memory:write_u32(address, value[1])
      else self.memory:write_u64(address, value) end
      address = address + increment
    end
    self.regs[7] = u64.from_number(address)
    if r.prefixes.rep then self.regs[1] = u64.zero() end
    mnemonic = "stos"
  elseif op == 0xf6 or op == 0xf7 then
    local mr = r:modrm()
    local width = op == 0xf6 and 8 or bits
    if mr.opcode == 0 then
      local imm = width == 8 and r:u8() or width == 16 and r:u16() or r:i32()
      self:binary("test", mr.operand, u64.from_signed(imm), width, r.pos, false)
      mnemonic = "test"
    elseif mr.opcode == 2 then
      self:write_operand(mr.operand, mask(u64.bnot(self:read_operand(mr.operand, width, r.pos)), width), width, r.pos)
      mnemonic = "not"
    elseif mr.opcode == 3 then
      local value = self:read_operand(mr.operand, width, r.pos)
      local result_value = mask(u64.neg(value), width)
      self:set_arithmetic_flags("sub", u64.zero(), value, result_value, width)
      self:write_operand(mr.operand, result_value, width, r.pos)
      mnemonic = "neg"
    elseif mr.opcode == 4 or mr.opcode == 5 then
      if width == 64 then guest_fault(self, "SIGILL", "ILL_ILLOPN") end
      local left = mr.opcode == 5 and u64.sign_extend(self:get_reg(0, width), width) or self:get_reg(0, width)
      local right_value = self:read_operand(mr.operand, width, r.pos)
      local right = mr.opcode == 5 and u64.sign_extend(right_value, width) or right_value
      local product = u64.mul(left, right)
      local low, high = mask(product, width), u64.shr(product, width)
      if width == 8 then
        self:set_reg(0, u64.new(bit32.bor(low[1], bit32.lshift(bit32.band(high[1], 0xff), 8)), 0), 16)
      else
        self:set_reg(0, low, width); self:set_reg(2, high, width)
      end
      local overflow
      if mr.opcode == 4 then overflow = not u64.is_zero(high)
      else overflow = not u64.eq(product, u64.sign_extend(low, width)) end
      self:set_multiply_flags(overflow)
      mnemonic = mr.opcode == 4 and "mul" or "imul"
    elseif mr.opcode == 6 or mr.opcode == 7 then
      local divisor_value = self:read_operand(mr.operand, width, r.pos)
      local divisor = mr.opcode == 7 and u64.sign_extend(divisor_value, width) or divisor_value
      if u64.is_zero(divisor) then guest_fault(self, "SIGFPE", "FPE_INTDIV") end
      local dividend
      if width == 8 then dividend = self:get_reg(0, 16)
      elseif width == 16 then
        dividend = u64.new(bit32.bor(bit32.band(self.regs[0][1], 0xffff),
          bit32.lshift(bit32.band(self.regs[2][1], 0xffff), 16)), 0)
      elseif width == 32 then dividend = u64.new(self.regs[0][1], self.regs[2][1])
      elseif u64.is_zero(self.regs[2]) then dividend = u64.clone(self.regs[0])
      else guest_fault(self, "SIGFPE", "FPE_INTOVF") end
      if mr.opcode == 7 then dividend = u64.sign_extend(dividend, math.min(width * 2, 64)) end
      local quotient, remainder = (mr.opcode == 7 and u64.sdivmod or u64.divmod)(dividend, divisor)
      local fits
      if mr.opcode == 6 then fits = u64.eq(quotient, mask(quotient, width))
      else
        local signed_quotient = u64.to_signed_number(quotient)
        fits = signed_quotient >= -(2 ^ (width - 1)) and signed_quotient < 2 ^ (width - 1)
      end
      if not fits then guest_fault(self, "SIGFPE", "FPE_INTOVF") end
      if width == 8 then
        self:set_reg(0, u64.new(bit32.bor(bit32.band(quotient[1], 0xff),
          bit32.lshift(bit32.band(remainder[1], 0xff), 8)), 0), 16)
      else
        self:set_reg(0, quotient, width); self:set_reg(2, remainder, width)
      end
      mnemonic = mr.opcode == 6 and "div" or "idiv"
    else guest_fault(self, "SIGILL", "ILL_ILLOPN") end
  elseif op == 0x0f then
    local op2 = r:u8()
    if op2 == 0x05 then
      if not self.syscall then guest_fault(self, "SIGSYS", "SYS_SECCOMP") end
      self.syscall(self); mnemonic = "syscall"
    elseif op2 == 0xa2 then
      local leaf = self.regs[0][1]
      if leaf == 0 then
        self:set_reg(0, u64.new(1, 0), 32)
        self:set_reg(3, u64.new(0x66617243, 0), 32) -- EBX: "Craf"
        self:set_reg(2, u64.new(0x696c4274, 0), 32) -- EDX: "tBli"
        self:set_reg(1, u64.new(0x20206b6e, 0), 32) -- ECX: "nk  "
      elseif leaf == 1 then
        self:set_reg(0, u64.new(0x00000663, 0), 32)
        self:set_reg(1, u64.zero(), 32); self:set_reg(2, u64.new(1, 0), 32); self:set_reg(3, u64.zero(), 32)
      elseif leaf == 0x80000000 then
        self:set_reg(0, u64.new(0x80000001, 0), 32)
        self:set_reg(1, u64.zero(), 32); self:set_reg(2, u64.zero(), 32); self:set_reg(3, u64.zero(), 32)
      elseif leaf == 0x80000001 then
        self:set_reg(0, u64.zero(), 32); self:set_reg(1, u64.zero(), 32); self:set_reg(3, u64.zero(), 32)
        self:set_reg(2, u64.new(bit32.bor(bit32.lshift(1, 11), bit32.lshift(1, 20), bit32.lshift(1, 29)), 0), 32)
      else
        self:set_reg(0, u64.zero(), 32); self:set_reg(1, u64.zero(), 32)
        self:set_reg(2, u64.zero(), 32); self:set_reg(3, u64.zero(), 32)
      end
      mnemonic = "cpuid"
    elseif op2 == 0x01 then
      local modrm = r:u8()
      if modrm ~= 0xd0 or self.regs[1][1] ~= 0 or self.regs[1][2] ~= 0 then
        guest_fault(self, "SIGILL", "ILL_ILLOPN")
      end
      self:set_reg(0, u64.one(), 32); self:set_reg(2, u64.zero(), 32); mnemonic = "xgetbv"
    elseif op2 == 0x6e and r.prefixes.operand then
      local mr = r:modrm()
      local width = bit32.band(r.rex, 8) ~= 0 and 64 or 32
      local value = self:read_operand(mr.operand, width, r.pos)
      self.xmm[mr.reg] = { value[1], width == 64 and value[2] or 0, 0, 0 }
      mnemonic = width == 64 and "movq" or "movd"
    elseif op2 == 0x7e and r.prefixes.operand then
      local mr = r:modrm()
      local width = bit32.band(r.rex, 8) ~= 0 and 64 or 32
      self:write_operand(mr.operand, u64.new(self.xmm[mr.reg][1], self.xmm[mr.reg][2]), width, r.pos)
      mnemonic = width == 64 and "movq" or "movd"
    elseif op2 == 0x28 or op2 == 0x10 or (op2 == 0x6f and (r.prefixes.operand or r.prefixes.rep)) then
      local mr = r:modrm()
      self.xmm[mr.reg] = self:read_xmm_operand(mr.operand, r.pos)
      mnemonic = op2 == 0x28 and "movaps" or op2 == 0x10 and "movups"
        or r.prefixes.rep and "movdqu" or "movdqa"
    elseif op2 == 0x29 or op2 == 0x11 or (op2 == 0x7f and r.prefixes.operand) then
      local mr = r:modrm()
      self:write_xmm_operand(mr.operand, self.xmm[mr.reg], r.pos)
      mnemonic = op2 == 0x29 and "movaps" or op2 == 0x11 and "movups" or "movdqa"
    elseif op2 == 0x6c and r.prefixes.operand then
      local mr = r:modrm()
      local source, destination = self:read_xmm_operand(mr.operand, r.pos), self.xmm[mr.reg]
      self.xmm[mr.reg] = { destination[1], destination[2], source[1], source[2] }
      mnemonic = "punpcklqdq"
    elseif op2 == 0xef and r.prefixes.operand then
      local mr = r:modrm()
      local source, destination = self:read_xmm_operand(mr.operand, r.pos), self.xmm[mr.reg]
      self.xmm[mr.reg] = { bit32.bxor(destination[1], source[1]), bit32.bxor(destination[2], source[2]),
        bit32.bxor(destination[3], source[3]), bit32.bxor(destination[4], source[4]) }
      mnemonic = "pxor"
    elseif op2 == 0x70 and r.prefixes.operand then
      local mr = r:modrm()
      local source, control = self:read_xmm_operand(mr.operand, r.pos), r:u8()
      local shuffled = {}
      for lane = 0, 3 do
        shuffled[lane + 1] = source[bit32.band(bit32.rshift(control, lane * 2), 3) + 1]
      end
      self.xmm[mr.reg] = shuffled
      mnemonic = "pshufd"
    elseif op2 == 0xaf then
      local mr = r:modrm()
      local left = u64.sign_extend(self:get_reg(mr.reg, bits), bits)
      local right = u64.sign_extend(self:read_operand(mr.operand, bits, r.pos), bits)
      local result_value = u64.mul(left, right)
      local overflow = signed_multiply_overflow(left, right, bits)
      self:set_multiply_flags(overflow)
      self:set_reg(mr.reg, mask(result_value, bits), bits)
      mnemonic = "imul"
    elseif op2 == 0xa3 then
      local mr = r:modrm()
      local index = self:get_reg(mr.reg, bits)[1] % bits
      local value = self:read_operand(mr.operand, bits, r.pos)
      self.rflags = bit32.band(self.rflags, bit32.bnot(flags.CF))
      if u64.bit(value, index) ~= 0 then self.rflags = bit32.bor(self.rflags, flags.CF) end
      mnemonic = "bt"
    elseif op2 == 0xba then
      local mr = r:modrm()
      if mr.opcode < 4 then guest_fault(self, "SIGILL", "ILL_ILLOPN") end
      local index = r:u8() % bits
      local value = self:read_operand(mr.operand, bits, r.pos)
      local bit_value = u64.shl(u64.one(), index)
      self.rflags = bit32.band(self.rflags, bit32.bnot(flags.CF))
      if u64.bit(value, index) ~= 0 then self.rflags = bit32.bor(self.rflags, flags.CF) end
      if mr.opcode == 5 then self:write_operand(mr.operand, u64.bor(value, bit_value), bits, r.pos)
      elseif mr.opcode == 6 then self:write_operand(mr.operand, u64.band(value, u64.bnot(bit_value)), bits, r.pos)
      elseif mr.opcode == 7 then self:write_operand(mr.operand, u64.bxor(value, bit_value), bits, r.pos) end
      mnemonic = mr.opcode == 4 and "bt" or mr.opcode == 5 and "bts" or mr.opcode == 6 and "btr" or "btc"
    elseif op2 >= 0x80 and op2 <= 0x8f then
      local d = r:i32(); if flags.condition(op2 - 0x80, self.rflags) then r.pos = r.pos + d end; mnemonic = "jcc"
    elseif op2 >= 0x40 and op2 <= 0x4f then
      local mr = r:modrm()
      if flags.condition(op2 - 0x40, self.rflags) then
        self:set_reg(mr.reg, self:read_operand(mr.operand, bits, r.pos), bits)
      end
      mnemonic = "cmovcc"
    elseif op2 >= 0x90 and op2 <= 0x9f then
      local mr = r:modrm()
      self:write_operand(mr.operand, u64.new(flags.condition(op2 - 0x90, self.rflags) and 1 or 0, 0), 8, r.pos)
      mnemonic = "setcc"
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
