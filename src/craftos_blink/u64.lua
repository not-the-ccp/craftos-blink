-- Exact 64-bit arithmetic for Lua 5.2 / ComputerCraft.
-- Values are immutable normalized { lo, hi } unsigned 32-bit words.
local bit = bit32
assert(bit, "CraftOS Blink requires the ComputerCraft-compatible bit32 library")

local M = {}
local TWO16, TWO32 = 65536, 4294967296

local function u32(x)
  return x % TWO32
end

function M.new(lo, hi)
  return { u32(lo or 0), u32(hi or 0) }
end

M.zero = function() return { 0, 0 } end
M.one = function() return { 1, 0 } end

function M.clone(a) return { a[1], a[2] } end
function M.is_zero(a) return a[1] == 0 and a[2] == 0 end
function M.eq(a, b) return a[1] == b[1] and a[2] == b[2] end

function M.from_number(n)
  assert(n >= 0 and n < 9007199254740992 and n == math.floor(n),
    "u64.from_number requires an exact non-negative integer below 2^53")
  return { n % TWO32, math.floor(n / TWO32) }
end

function M.from_signed(n)
  assert(n == math.floor(n) and n > -9007199254740992 and n < 9007199254740992,
    "u64.from_signed requires an exact integer")
  if n >= 0 then return M.from_number(n) end
  return M.neg(M.from_number(-n))
end

function M.to_number(a)
  assert(a[2] < 2097152, "u64 is not exactly representable as a Lua number")
  return a[2] * TWO32 + a[1]
end

function M.to_signed_number(a)
  if a[2] < 0x80000000 then return M.to_number(a) end
  local n = M.neg(a)
  assert(n[2] < 2097152, "signed u64 is not exactly representable as a Lua number")
  return -(n[2] * TWO32 + n[1])
end

function M.add(a, b)
  local lo = a[1] + b[1]
  local carry = lo >= TWO32 and 1 or 0
  return { lo % TWO32, (a[2] + b[2] + carry) % TWO32 }
end

function M.add32(a, b)
  local lo = a[1] + u32(b)
  return { lo % TWO32, (a[2] + (lo >= TWO32 and 1 or 0)) % TWO32 }
end

function M.bnot(a) return { bit.bnot(a[1]), bit.bnot(a[2]) } end
function M.neg(a) return M.add32(M.bnot(a), 1) end
function M.sub(a, b) return M.add(a, M.neg(b)) end
function M.band(a, b) return { bit.band(a[1], b[1]), bit.band(a[2], b[2]) } end
function M.bor(a, b) return { bit.bor(a[1], b[1]), bit.bor(a[2], b[2]) } end
function M.bxor(a, b) return { bit.bxor(a[1], b[1]), bit.bxor(a[2], b[2]) } end

function M.cmp(a, b)
  if a[2] ~= b[2] then return a[2] < b[2] and -1 or 1 end
  if a[1] ~= b[1] then return a[1] < b[1] and -1 or 1 end
  return 0
end

function M.scmp(a, b)
  local sa, sb = a[2] >= 0x80000000, b[2] >= 0x80000000
  if sa ~= sb then return sa and -1 or 1 end
  return M.cmp(a, b)
end

function M.shl(a, n)
  n = n % 64
  if n == 0 then return M.clone(a) end
  if n < 32 then
    return { bit.lshift(a[1], n), bit.bor(bit.lshift(a[2], n), bit.rshift(a[1], 32 - n)) }
  end
  return { 0, bit.lshift(a[1], n - 32) }
end

function M.shr(a, n)
  n = n % 64
  if n == 0 then return M.clone(a) end
  if n < 32 then
    return { bit.bor(bit.rshift(a[1], n), bit.lshift(a[2], 32 - n)), bit.rshift(a[2], n) }
  end
  return { bit.rshift(a[2], n - 32), 0 }
end

function M.sar(a, n)
  n = n % 64
  if n == 0 then return M.clone(a) end
  local negative = a[2] >= 0x80000000
  if n < 32 then
    return {
      bit.bor(bit.rshift(a[1], n), bit.lshift(a[2], 32 - n)),
      bit.arshift(a[2], n)
    }
  end
  return { bit.arshift(a[2], n - 32), negative and 0xffffffff or 0 }
end

function M.rol(a, n)
  n = n % 64
  if n == 0 then return M.clone(a) end
  return M.bor(M.shl(a, n), M.shr(a, 64 - n))
end

function M.ror(a, n) return M.rol(a, 64 - (n % 64)) end

-- 16-bit limbs keep every intermediate exactly representable by doubles.
function M.mul_wide(a, b)
  local x = { a[1] % TWO16, math.floor(a[1] / TWO16), a[2] % TWO16, math.floor(a[2] / TWO16) }
  local y = { b[1] % TWO16, math.floor(b[1] / TWO16), b[2] % TWO16, math.floor(b[2] / TWO16) }
  local z = { 0, 0, 0, 0, 0, 0, 0, 0 }
  for i = 1, 4 do
    for j = 1, 4 do z[i + j - 1] = z[i + j - 1] + x[i] * y[j] end
  end
  for i = 1, 7 do
    local carry = math.floor(z[i] / TWO16)
    z[i], z[i + 1] = z[i] % TWO16, z[i + 1] + carry
  end
  z[8] = z[8] % TWO16
  return { z[1] + z[2] * TWO16, z[3] + z[4] * TWO16 },
    { z[5] + z[6] * TWO16, z[7] + z[8] * TWO16 }
end

function M.mul(a, b)
  local low = M.mul_wide(a, b)
  return low
end

local function words128(high, low) return { low[1], low[2], high[1], high[2] } end

local function cmp128(a, b)
  for i = 4, 1, -1 do
    if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
  end
  return 0
end

local function sub128(a, b)
  local result, borrow = {}, 0
  for i = 1, 4 do
    local difference = a[i] - b[i] - borrow
    if difference < 0 then difference, borrow = difference + TWO32, 1 else borrow = 0 end
    result[i] = difference
  end
  return result
end

local function shl128(a)
  local result, carry = {}, 0
  for i = 1, 4 do
    result[i] = bit.bor(bit.lshift(a[i], 1), carry)
    carry = bit.rshift(a[i], 31)
  end
  return result
end

function M.divmod128(high, low, divisor)
  assert(not M.is_zero(divisor), "integer division by zero")
  local dividend = words128(high, low)
  local divisor128 = { divisor[1], divisor[2], 0, 0 }
  local remainder, quotient, overflow = { 0, 0, 0, 0 }, { 0, 0 }, false
  for i = 127, 0, -1 do
    remainder = shl128(remainder)
    local word_index, bit_index = math.floor(i / 32) + 1, i % 32
    if bit.band(bit.rshift(dividend[word_index], bit_index), 1) ~= 0 then
      remainder[1] = bit.bor(remainder[1], 1)
    end
    if cmp128(remainder, divisor128) >= 0 then
      remainder = sub128(remainder, divisor128)
      if i >= 64 then overflow = true
      else
        local qword = math.floor(i / 32) + 1
        quotient[qword] = bit.bor(quotient[qword], bit.lshift(1, i % 32))
      end
    end
  end
  return { quotient[1], quotient[2] }, { remainder[1], remainder[2] }, overflow
end

function M.neg128(high, low)
  local result_low = M.neg(low)
  local result_high = M.bnot(high)
  if M.is_zero(result_low) then result_high = M.add32(result_high, 1) end
  return result_high, result_low
end

function M.bit(a, n)
  if n < 32 then return bit.band(bit.rshift(a[1], n), 1) end
  return bit.band(bit.rshift(a[2], n - 32), 1)
end

function M.setbit(a, n)
  local r = M.clone(a)
  if n < 32 then r[1] = bit.bor(r[1], bit.lshift(1, n))
  else r[2] = bit.bor(r[2], bit.lshift(1, n - 32)) end
  return r
end

function M.divmod(a, b)
  assert(not M.is_zero(b), "integer division by zero")
  local q, r = M.zero(), M.zero()
  for i = 63, 0, -1 do
    r = M.shl(r, 1)
    if M.bit(a, i) ~= 0 then r[1] = bit.bor(r[1], 1) end
    if M.cmp(r, b) >= 0 then
      r = M.sub(r, b)
      q = M.setbit(q, i)
    end
  end
  return q, r
end

function M.sdivmod(a, b)
  assert(not M.is_zero(b), "integer division by zero")
  local an, bn = a[2] >= 0x80000000, b[2] >= 0x80000000
  local q, r = M.divmod(an and M.neg(a) or a, bn and M.neg(b) or b)
  if an ~= bn then q = M.neg(q) end
  if an then r = M.neg(r) end
  return q, r
end

function M.sign_extend(value, bits)
  assert(bits >= 1 and bits <= 64)
  if bits == 64 then return M.clone(value) end
  local masked
  if bits <= 32 then
    local mask = bits == 32 and 0xffffffff or (2 ^ bits - 1)
    masked = { bit.band(value[1], mask), 0 }
  else
    local highbits = bits - 32
    local mask = highbits == 32 and 0xffffffff or (2 ^ highbits - 1)
    masked = { value[1], bit.band(value[2], mask) }
  end
  if M.bit(masked, bits - 1) == 0 then return masked end
  if bits <= 32 then
    masked[1] = bit.bor(masked[1], bit.bnot(2 ^ bits - 1))
    masked[2] = 0xffffffff
  else
    masked[2] = bit.bor(masked[2], bit.bnot(2 ^ (bits - 32) - 1))
  end
  return masked
end

function M.from_le(s, offset, size)
  offset, size = offset or 1, size or 8
  assert(size >= 1 and size <= 8)
  local lo, hi = 0, 0
  for i = 0, size - 1 do
    local v = s:byte(offset + i)
    assert(v, "short little-endian input")
    if i < 4 then lo = lo + v * 2 ^ (i * 8)
    else hi = hi + v * 2 ^ ((i - 4) * 8) end
  end
  return { lo, hi }
end

function M.to_le(a, size)
  size = size or 8
  local out = {}
  for i = 0, size - 1 do
    local word, shift = i < 4 and a[1] or a[2], (i % 4) * 8
    out[i + 1] = string.char(bit.band(bit.rshift(word, shift), 0xff))
  end
  return table.concat(out)
end

function M.hex(a) return string.format("%08x%08x", a[2], a[1]) end

return M
