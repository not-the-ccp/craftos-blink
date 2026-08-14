local u64 = require("craftos_blink.u64")

local M = {}
M.__index = M
M.PAGE_SIZE = 4096
M.PROT_READ, M.PROT_WRITE, M.PROT_EXEC = 1, 2, 4

local function fault(kind, address, access)
  error({ class = "guest_fault", signal = "SIGSEGV", code = kind,
    address = address, access = access }, 0)
end

local function page_number(address)
  assert(type(address) == "number" and address >= 0 and address < 9007199254740992
    and address == math.floor(address), "invalid guest address")
  return math.floor(address / M.PAGE_SIZE), address % M.PAGE_SIZE
end

local function blank_backing()
  return { bytes = {}, refs = 1 }
end

function M.new(options)
  options = options or {}
  return setmetatable({ pages = {}, mapped_pages = 0,
    max_pages = options.max_pages or 65536, generation = 0 }, M)
end

local function check_aligned(address, length)
  assert(address % M.PAGE_SIZE == 0, "mapping address is not page aligned")
  assert(length > 0 and length == math.floor(length), "invalid mapping length")
end

function M:map(address, length, prot, options)
  check_aligned(address, length)
  options = options or {}
  local count = math.ceil(length / M.PAGE_SIZE)
  if self.mapped_pages + count > self.max_pages then
    error({ class = "resource_limit", resource = "memory" }, 0)
  end
  for i = 0, count - 1 do
    local pn = page_number(address + i * M.PAGE_SIZE)
    if self.pages[pn] and not options.replace then
      error({ class = "mapping_conflict", address = address + i * M.PAGE_SIZE }, 0)
    end
  end
  for i = 0, count - 1 do
    local pn = page_number(address + i * M.PAGE_SIZE)
    if not self.pages[pn] then self.mapped_pages = self.mapped_pages + 1 end
    self.pages[pn] = { backing = blank_backing(), prot = prot, cow = false,
      shared = options.shared or false, generation = 0 }
  end
  self.generation = self.generation + 1
  return address
end

function M:unmap(address, length)
  check_aligned(address, length)
  for i = 0, math.ceil(length / M.PAGE_SIZE) - 1 do
    local pn = page_number(address + i * M.PAGE_SIZE)
    local p = self.pages[pn]
    if p then
      p.backing.refs = p.backing.refs - 1
      self.pages[pn], self.mapped_pages = nil, self.mapped_pages - 1
    end
  end
  self.generation = self.generation + 1
end

function M:protect(address, length, prot)
  check_aligned(address, length)
  for i = 0, math.ceil(length / M.PAGE_SIZE) - 1 do
    local pn = page_number(address + i * M.PAGE_SIZE)
    local p = self.pages[pn]
    if not p then fault("SEGV_MAPERR", address + i * M.PAGE_SIZE, "protect") end
    p.prot, p.generation = prot, p.generation + 1
  end
  self.generation = self.generation + 1
end

function M:_page(address, permission, access)
  local pn, offset = page_number(address)
  local p = self.pages[pn]
  if not p then fault("SEGV_MAPERR", address, access) end
  if bit32.band(p.prot, permission) == 0 then fault("SEGV_ACCERR", address, access) end
  return p, offset, pn
end

function M:_writable(address)
  local p, offset = self:_page(address, M.PROT_WRITE, "write")
  if p.cow and p.backing.refs > 1 then
    local bytes = {}
    for k, v in pairs(p.backing.bytes) do bytes[k] = v end
    p.backing.refs = p.backing.refs - 1
    p.backing = { bytes = bytes, refs = 1 }
    p.cow = false
  end
  return p, offset
end

function M:read8(address, access)
  local p, offset = self:_page(address, access == "execute" and M.PROT_EXEC or M.PROT_READ,
    access or "read")
  return p.backing.bytes[offset] or 0
end

function M:write8(address, value)
  local p, offset = self:_writable(address)
  value = value % 256
  p.backing.bytes[offset] = value == 0 and nil or value
  if bit32.band(p.prot, M.PROT_EXEC) ~= 0 then
    p.generation, self.generation = p.generation + 1, self.generation + 1
  end
end

function M:read(address, length, access)
  local out, chunk = {}, {}
  for i = 0, length - 1 do
    chunk[#chunk + 1] = string.char(self:read8(address + i, access))
    if #chunk == 256 then out[#out + 1], chunk = table.concat(chunk), {} end
  end
  out[#out + 1] = table.concat(chunk)
  return table.concat(out)
end

function M:write(address, data)
  for i = 1, #data do self:write8(address + i - 1, data:byte(i)) end
end

function M:read_u16(a, access)
  return self:read8(a, access) + self:read8(a + 1, access) * 256
end

function M:read_u32(a, access)
  return self:read_u16(a, access) + self:read_u16(a + 2, access) * 65536
end

function M:read_u64(a, access) return u64.new(self:read_u32(a, access), self:read_u32(a + 4, access)) end
function M:write_u16(a, v) self:write8(a, v); self:write8(a + 1, math.floor(v / 256)) end
function M:write_u32(a, v) self:write_u16(a, v); self:write_u16(a + 2, math.floor(v / 65536)) end
function M:write_u64(a, v) self:write_u32(a, v[1]); self:write_u32(a + 4, v[2]) end

function M:fork()
  local child = M.new({ max_pages = self.max_pages })
  child.mapped_pages, child.generation = self.mapped_pages, self.generation
  for pn, p in pairs(self.pages) do
    p.backing.refs = p.backing.refs + 1
    local cow = not p.shared and bit32.band(p.prot, M.PROT_WRITE) ~= 0
    if cow then p.cow = true end
    child.pages[pn] = { backing = p.backing, prot = p.prot,
      cow = cow or p.cow, shared = p.shared, generation = p.generation }
  end
  return child
end

function M:mappings()
  local result = {}
  for pn, p in pairs(self.pages) do
    result[#result + 1] = { address = pn * M.PAGE_SIZE, prot = p.prot,
      shared = p.shared, cow = p.cow, generation = p.generation }
  end
  table.sort(result, function(a, b) return a.address < b.address end)
  return result
end

return M

