local u64 = require("craftos_blink.u64")
local Memory = require("craftos_blink.memory")

local M = {}
M.__index = M

local errno = { EPERM = 1, ENOENT = 2, EBADF = 9, EAGAIN = 11, EACCES = 13,
  EFAULT = 14, EINVAL = 22, ENOSYS = 38, EAFNOSUPPORT = 97, ENETDOWN = 100 }

local function result(cpu, value)
  cpu:set_reg(0, value < 0 and u64.from_signed(value) or u64.from_number(value), 64)
end

local function number(cpu, reg) return u64.to_number(cpu.regs[reg]) end

local function write_handle(handle, data)
  if (type(handle) == "table" or type(handle) == "userdata") and handle.write then
    local ok = pcall(handle.write, data)
    if not ok then handle:write(data) end
  elseif type(handle) == "function" then handle(data)
  elseif type(write) == "function" then write(data)
  elseif type(io) == "table" and io.write then io.write(data)
  else error("no host output handle", 0) end
end

local function read_handle(fd, count)
  if count <= 0 then return "" end
  if fd.pending and #fd.pending > 0 then
    local data = fd.pending:sub(1, count)
    fd.pending = fd.pending:sub(#data + 1)
    return data
  end

  local handle, data = fd.handle
  if (type(handle) == "table" or type(handle) == "userdata") and handle.read then
    local ok
    ok, data = pcall(handle.read, count)
    if not ok then ok, data = pcall(handle.read, handle, count) end
    if not ok then error(data, 0) end
  elseif type(handle) == "function" then
    data = handle(count)
  elseif type(read) == "function" then
    local line = read()
    if line ~= nil then data = line .. "\n" end
  end

  if not data then return "" end
  if #data > count then
    fd.pending = data:sub(count + 1)
    data = data:sub(1, count)
  end
  return data
end

function M.new(memory, vfs, options)
  options = options or {}
  local self = setmetatable({ memory = memory, vfs = vfs, pid = 1, syscalls = 0,
    exited = false, exit_code = nil, brk = options.brk or 0x70000000,
    mmap_next = options.mmap_base or 0x71000000, seed = options.seed or 0x4b1d,
    trace = options.trace, fds = {}, next_fd = 3 }, M)
  local host_io = type(io) == "table" and io or {}
  self.fds[0] = { kind = "stdio", handle = options.stdin or host_io.stdin, readable = true }
  self.fds[1] = { kind = "stdio", handle = options.stdout or host_io.stdout, writable = true }
  self.fds[2] = { kind = "stdio", handle = options.stderr or host_io.stderr, writable = true }
  return self
end

function M:cstring(address, limit)
  local out = {}
  for i = 0, (limit or 4096) - 1 do
    local b = self.memory:read8(address + i)
    if b == 0 then return table.concat(out) end
    out[#out + 1] = string.char(b)
  end
  return nil
end

function M:random_byte()
  local x = self.seed
  x = bit32.bxor(x, bit32.lshift(x, 13)); x = bit32.bxor(x, bit32.rshift(x, 17)); x = bit32.bxor(x, bit32.lshift(x, 5))
  self.seed = x
  return bit32.band(x, 0xff)
end

function M:open(path, flags)
  local data, err = self.vfs:read_file(path)
  if not data then return -(errno[err] or errno.ENOENT) end
  local fd = self.next_fd; self.next_fd = fd + 1
  self.fds[fd] = { kind = "file", path = path, data = data, pos = 1,
    readable = true, writable = bit32.band(flags or 0, 3) ~= 0 }
  return fd
end

function M:dispatch(cpu)
  local nr = cpu.regs[0][1]
  local a1, a2, a3, a4, a5, a6 = number(cpu, 7), number(cpu, 6), number(cpu, 2),
    number(cpu, 10), number(cpu, 8), number(cpu, 9)
  self.syscalls = self.syscalls + 1
  if self.trace then self.trace({ number = nr, args = { a1, a2, a3, a4, a5, a6 } }) end

  if nr == 1 then -- write
    local fd = self.fds[a1]
    if not fd or not fd.writable then result(cpu, -errno.EBADF)
    else
      local data = self.memory:read(a2, a3)
      if fd.kind == "stdio" then write_handle(fd.handle, data)
      else
        local before, after = fd.data:sub(1, fd.pos - 1), fd.data:sub(fd.pos + #data)
        fd.data, fd.pos = before .. data .. after, fd.pos + #data
      end
      result(cpu, #data)
    end
  elseif nr == 0 then -- read
    local fd = self.fds[a1]
    if not fd or not fd.readable then result(cpu, -errno.EBADF)
    elseif fd.kind == "file" then
      local data = fd.data:sub(fd.pos, fd.pos + a3 - 1); fd.pos = fd.pos + #data
      self.memory:write(a2, data); result(cpu, #data)
    else
      local data = read_handle(fd, a3)
      self.memory:write(a2, data); result(cpu, #data)
    end
  elseif nr == 2 or nr == 257 then
    local path_address, flags_value = nr == 2 and a1 or a2, nr == 2 and a2 or a3
    local path = self:cstring(path_address)
    result(cpu, path and self:open(path, flags_value) or -errno.EFAULT)
  elseif nr == 3 then
    if a1 < 3 or not self.fds[a1] then result(cpu, -errno.EBADF)
    else self.fds[a1] = nil; result(cpu, 0) end
  elseif nr == 8 then
    local fd = self.fds[a1]
    if not fd or fd.kind ~= "file" then result(cpu, -errno.EBADF)
    else
      local offset = u64.to_signed_number(cpu.regs[6])
      local base = a3 == 0 and 1 or a3 == 1 and fd.pos or #fd.data + 1
      fd.pos = math.max(1, base + offset); result(cpu, fd.pos - 1)
    end
  elseif nr == 9 then
    local length = math.ceil(a2 / 4096) * 4096
    local address = a1 ~= 0 and a1 or self.mmap_next
    if a1 == 0 then self.mmap_next = self.mmap_next + length end
    local prot = bit32.band(a3, 7)
    local ok = pcall(function() self.memory:map(address, length, prot) end)
    result(cpu, ok and address or -errno.EINVAL)
  elseif nr == 10 then
    local ok = pcall(function() self.memory:protect(a1 - a1 % 4096, math.ceil(a2 / 4096) * 4096, bit32.band(a3, 7)) end)
    result(cpu, ok and 0 or -errno.EINVAL)
  elseif nr == 11 then self.memory:unmap(a1 - a1 % 4096, math.ceil(a2 / 4096) * 4096); result(cpu, 0)
  elseif nr == 12 then
    if a1 == 0 then result(cpu, self.brk) else self.brk = a1; result(cpu, self.brk) end
  elseif nr == 39 or nr == 186 then result(cpu, self.pid)
  elseif nr == 60 or nr == 231 then
    self.exited, self.exit_code, cpu.halted = true, bit32.band(a1, 0xff), true; result(cpu, 0)
  elseif nr == 63 then
    local fields = { "Linux", "craftos", "6.6.0-craftos-blink", "#1", "x86_64", "(none)" }
    for i, value in ipairs(fields) do self.memory:write(a1 + (i - 1) * 65, value .. "\0" .. string.rep("\0", 64 - #value)) end
    result(cpu, 0)
  elseif nr == 79 then
    local cwd = self.vfs.cwd
    if #cwd + 1 > a2 then result(cpu, -34) else self.memory:write(a1, cwd .. "\0"); result(cpu, a1) end
  elseif nr == 158 then
    if a1 == 0x1002 then cpu.fs_base = a2; result(cpu, 0)
    elseif a1 == 0x1001 then cpu.gs_base = a2; result(cpu, 0)
    elseif a1 == 0x1003 then self.memory:write_u64(a2, u64.from_number(cpu.fs_base)); result(cpu, 0)
    elseif a1 == 0x1004 then self.memory:write_u64(a2, u64.from_number(cpu.gs_base)); result(cpu, 0)
    else result(cpu, -errno.EINVAL) end
  elseif nr == 218 or nr == 273 then result(cpu, self.pid)
  elseif nr == 228 then
    local ms = type(os.epoch) == "function" and os.epoch("utc") or math.floor(os.time() * 1000)
    local sec = math.floor(ms / 1000); self.memory:write_u64(a2, u64.from_number(sec)); self.memory:write_u64(a2 + 8, u64.from_number((ms % 1000) * 1000000)); result(cpu, 0)
  elseif nr == 318 then
    for i = 0, a2 - 1 do self.memory:write8(a1 + i, self:random_byte()) end; result(cpu, a2)
  elseif nr == 41 then result(cpu, a1 == 1 and -errno.ENOSYS or -errno.EAFNOSUPPORT)
  elseif nr == 13 or nr == 14 or nr == 16 or nr == 72 then result(cpu, 0)
  else result(cpu, -errno.ENOSYS) end
end

M.errno = errno
return M
