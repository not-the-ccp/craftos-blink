local M = {}

local Reader = {}
Reader.__index = Reader

function M.reader(memory, rip)
  return setmetatable({ memory = memory, start = rip, pos = rip, prefixes = {} }, Reader)
end

function Reader:u8()
  local v = self.memory:read8(self.pos, "execute")
  self.pos = self.pos + 1
  return v
end

function Reader:u16() local a, b = self:u8(), self:u8(); return a + b * 256 end
function Reader:u32() return self:u16() + self:u16() * 65536 end
function Reader:i8() local v = self:u8(); return v >= 128 and v - 256 or v end
function Reader:i32() local v = self:u32(); return v >= 2147483648 and v - 4294967296 or v end

function Reader:prefixes64()
  local rex = 0
  while true do
    local b = self.memory:read8(self.pos, "execute")
    if b == 0x66 then self.prefixes.operand = true; self.pos = self.pos + 1
    elseif b == 0x67 then self.prefixes.address = true; self.pos = self.pos + 1
    elseif b == 0xf0 then self.prefixes.lock = true; self.pos = self.pos + 1
    elseif b == 0xf2 then self.prefixes.repne = true; self.pos = self.pos + 1
    elseif b == 0xf3 then self.prefixes.rep = true; self.pos = self.pos + 1
    elseif b == 0x2e or b == 0x36 or b == 0x3e or b == 0x26 or b == 0x64 or b == 0x65 then
      self.prefixes.segment = b; self.pos = self.pos + 1
    elseif b >= 0x40 and b <= 0x4f then rex = b; self.pos = self.pos + 1
    else break end
    if self.pos - self.start >= 15 then
      error({ class = "guest_fault", signal = "SIGILL", code = "ILL_ILLOPN", address = self.start }, 0)
    end
  end
  self.rex = rex
  return rex
end

local function rexbit(rex, mask) return bit32.band(rex, mask) ~= 0 and 8 or 0 end

function Reader:modrm()
  local byte = self:u8()
  local mod = bit32.rshift(byte, 6)
  local reg = bit32.band(bit32.rshift(byte, 3), 7) + rexbit(self.rex, 4)
  local rm_low = bit32.band(byte, 7)
  local rm = rm_low + rexbit(self.rex, 1)
  local operand = { kind = mod == 3 and "reg" or "mem", reg = rm }
  local info = { byte = byte, mod = mod, opcode = bit32.band(bit32.rshift(byte, 3), 7),
    reg = reg, rm = rm, operand = operand }
  if mod == 3 then return info end

  operand.segment = self.prefixes.segment
  operand.disp, operand.scale = 0, 1
  if rm_low == 4 then
    local sib = self:u8()
    local scale_bits = bit32.rshift(sib, 6)
    local index_low = bit32.band(bit32.rshift(sib, 3), 7)
    local base_low = bit32.band(sib, 7)
    operand.scale = 2 ^ scale_bits
    if index_low ~= 4 or rexbit(self.rex, 2) ~= 0 then operand.index = index_low + rexbit(self.rex, 2) end
    if mod == 0 and base_low == 5 then operand.no_base = true
    else operand.base = base_low + rexbit(self.rex, 1) end
  elseif mod == 0 and rm_low == 5 then
    operand.rip_relative = true
  else
    operand.base = rm
  end

  if mod == 1 then operand.disp = self:i8()
  elseif mod == 2 or (mod == 0 and (operand.rip_relative or operand.no_base)) then operand.disp = self:i32() end
  return info
end

function M.operand_bits(reader, default64)
  if bit32.band(reader.rex or 0, 8) ~= 0 then return 64 end
  if reader.prefixes.operand then return 16 end
  return default64 and 64 or 32
end

return M
