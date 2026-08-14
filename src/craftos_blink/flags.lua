local M = {
  CF = 0x0001, PF = 0x0004, AF = 0x0010, ZF = 0x0040,
  SF = 0x0080, TF = 0x0100, IF = 0x0200, DF = 0x0400, OF = 0x0800,
}

local function parity8(v)
  v = bit32.bxor(v, bit32.rshift(v, 4))
  v = bit32.band(v, 0xf)
  return bit32.band(bit32.rshift(0x9669, v), 1) ~= 0
end

function M.logic(result, bits)
  local sign = bits == 64 and result[2] >= 0x80000000
    or bits < 64 and bit32.band(result[1], 2 ^ (bits - 1)) ~= 0
  local zero = result[1] == 0 and (bits <= 32 or result[2] == 0)
  local f = 0
  if zero then f = bit32.bor(f, M.ZF) end
  if sign then f = bit32.bor(f, M.SF) end
  if parity8(result[1]) then f = bit32.bor(f, M.PF) end
  return f
end

function M.condition(cc, flags)
  local function set(mask) return bit32.band(flags, mask) ~= 0 end
  local cf, pf, zf, sf, of = set(M.CF), set(M.PF), set(M.ZF), set(M.SF), set(M.OF)
  local conditions = {
    of, not of, cf, not cf, zf, not zf, cf or zf, not cf and not zf,
    sf, not sf, pf, not pf, sf ~= of, sf == of, zf or sf ~= of, not zf and sf == of,
  }
  return conditions[cc + 1]
end

return M

