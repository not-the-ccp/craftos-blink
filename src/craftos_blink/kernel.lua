local u64 = require("craftos_blink.u64")
local Memory = require("craftos_blink.memory")
local CPU = require("craftos_blink.cpu")
local ELF = require("craftos_blink.elf")

local M = {}
M.__index = M

local errno = { EPERM = 1, ENOENT = 2, EIO = 5, E2BIG = 7, ENOEXEC = 8, EBADF = 9,
  ECHILD = 10, EAGAIN = 11, ENOMEM = 12, EACCES = 13,
  EFAULT = 14, EEXIST = 17, ENOTDIR = 20, EISDIR = 21, EINVAL = 22, ENFILE = 23,
  EMFILE = 24, ENOTTY = 25, ESPIPE = 29, EPIPE = 32, ERANGE = 34, ENOSYS = 38,
  EAFNOSUPPORT = 97, ENETDOWN = 100 }

local O_ACCMODE, O_CREAT, O_EXCL, O_TRUNC = 3, 0x40, 0x80, 0x200
local O_APPEND, O_DIRECTORY, O_CLOEXEC = 0x400, 0x10000, 0x80000
local AT_FDCWD = -100
local DEFAULT_IO_LIMIT = 16 * 1024 * 1024

local function result(cpu, value)
  cpu:set_reg(0, value < 0 and u64.from_signed(value) or u64.from_number(value), 64)
end

local function number(cpu, reg)
  local value = cpu.regs[reg]
  if value[2] < 0x00200000 then return u64.to_number(value) end
  if value[2] >= 0xffe00000 then return u64.to_signed_number(value) end
  error({ class = "guest_fault", signal = "SIGSEGV", code = "SEGV_MAPERR", address = cpu.rip }, 0)
end

local syscall_argc = {
  [0] = 3, [1] = 3, [2] = 3, [3] = 1, [4] = 2, [5] = 2, [6] = 2, [8] = 3,
  [9] = 6, [10] = 3, [11] = 2, [12] = 1, [13] = 4, [14] = 4, [16] = 3,
  [20] = 3, [21] = 2, [22] = 1, [32] = 1, [33] = 2, [39] = 0, [41] = 3,
  [56] = 5, [57] = 0, [58] = 0, [59] = 3, [60] = 1, [61] = 4,
  [63] = 1, [72] = 3, [78] = 3, [79] = 2, [80] = 1, [83] = 2, [89] = 3,
  [95] = 1, [107] = 0, [110] = 0, [158] = 2, [186] = 0, [217] = 3,
  [218] = 1, [228] = 2, [231] = 1, [257] = 4, [262] = 4, [273] = 2, [318] = 3,
}

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
  local world = options.world or { processes = {}, next_pid = 2, file_nodes = {}, syscalls = 0 }
  if options.max_processes then world.max_processes = options.max_processes end
  local self = setmetatable({ memory = memory, vfs = vfs, pid = options.pid or 1,
    ppid = options.ppid or 0, world = world, state = "runnable", syscalls = 0,
    exited = false, exit_code = nil, brk = options.brk or 0x70000000,
    mmap_next = options.mmap_base or 0x71000000, seed = options.seed or 0x4b1d,
    trace = options.trace, instruction_trace = options.instruction_trace, fds = {},
    file_nodes = world.file_nodes, signal_actions = {}, signal_mask = u64.zero(),
    file_creation_mask = 0x12, io_limit = options.io_limit or DEFAULT_IO_LIMIT }, M)
  local host_io = type(io) == "table" and io or {}
  local stdin = options.stdin
  if not stdin and type(fs) == "table" and type(read) == "function" then
    stdin = function()
      local line = read()
      return line ~= nil and line .. "\n" or nil
    end
  end
  if not options.skip_stdio then
    self.fds[0] = { description = { kind = "stdio", handle = stdin or host_io.stdin, readable = true, refs = 1 } }
    self.fds[1] = { description = { kind = "stdio", handle = options.stdout or host_io.stdout, writable = true, refs = 1 } }
    self.fds[2] = { description = { kind = "stdio", handle = options.stderr or host_io.stderr, writable = true, refs = 1 } }
  end
  return self
end

function M:attach_cpu(cpu)
  self.cpu = cpu
  self.world.processes[self.pid] = self
  if not self.world.root then self.world.root = self end
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

function M:allocate_fd(minimum)
  for fd = math.max(0, minimum or 0), 1048575 do
    if not self.fds[fd] then return fd end
  end
  return nil
end

function M:close(fd)
  local entry = self.fds[fd]
  if not entry then return nil, "EBADF" end
  self.fds[fd] = nil
  entry.description.refs = entry.description.refs - 1
  if entry.description.refs == 0 and entry.description.pipe then
    local pipe = entry.description.pipe
    if entry.description.kind == "pipe_read" then pipe.readers = pipe.readers - 1
    else pipe.writers = pipe.writers - 1 end
    self:wake_pipe(pipe)
  end
  return true
end

function M:duplicate(oldfd, minimum, exact, cloexec)
  local source = self.fds[oldfd]
  if not source then return nil, "EBADF" end
  local newfd = exact or self:allocate_fd(minimum)
  if not newfd then return nil, "EMFILE" end
  if newfd == oldfd then return newfd end
  if self.fds[newfd] then self:close(newfd) end
  source.description.refs = source.description.refs + 1
  self.fds[newfd] = { description = source.description, cloexec = not not cloexec }
  return newfd
end

function M:path_for_at(dirfd, path)
  if path:sub(1, 1) == "/" or dirfd == nil or dirfd == AT_FDCWD then
    return self.vfs:guest_path(path)
  end
  local entry = self.fds[dirfd]
  if not entry then return nil, "EBADF" end
  local description = entry.description
  if description.kind ~= "directory" then return nil, "ENOTDIR" end
  local ok, normalized = pcall(self.vfs.guest_path_from, self.vfs, path, description.path)
  if not ok then return nil, "EACCES" end
  return normalized
end

function M:open(path, flags, dirfd)
  flags = flags or 0
  local access = bit32.band(flags, O_ACCMODE)
  if access == 3 then return -errno.EINVAL end
  local guest, path_error = self:path_for_at(dirfd, path)
  if not guest then return -(errno[path_error] or errno.EACCES) end
  local info, stat_error = self.vfs:stat(guest)
  local create = bit32.band(flags, O_CREAT) ~= 0
  if not info then
    if not create then return -(errno[stat_error] or errno.ENOENT) end
    local ok, write_error = self.vfs:write_file(guest, "")
    if not ok then return -(errno[write_error] or errno.EACCES) end
    info = { kind = "file", size = 0, path = guest }
  elseif create and bit32.band(flags, O_EXCL) ~= 0 then
    return -errno.EEXIST
  end
  if bit32.band(flags, O_DIRECTORY) ~= 0 and info.kind ~= "directory" then return -errno.ENOTDIR end
  if info.kind == "directory" and access ~= 0 then return -errno.EISDIR end

  local description = { kind = info.kind, path = guest, pos = 1, refs = 1,
    readable = access ~= 1, writable = access ~= 0, append = bit32.band(flags, O_APPEND) ~= 0,
    status_flags = bit32.band(flags, O_APPEND + O_ACCMODE) }
  if guest == "/dev/null" then description.kind = "null"
  elseif guest == "/dev/zero" then description.kind = "zero"
  elseif info.kind == "file" then
    local node = self.file_nodes[guest]
    if not node then
      local data, read_error = self.vfs:read_file(guest)
      if data == nil then return -(errno[read_error] or errno.EACCES) end
      node = { data = data }
      self.file_nodes[guest] = node
    end
    description.node = node
    if bit32.band(flags, O_TRUNC) ~= 0 and description.writable then
      local ok, write_error = self.vfs:write_file(guest, "")
      if not ok then return -(errno[write_error] or errno.EACCES) end
      node.data = ""
    end
  end
  local fd = self:allocate_fd(0)
  if not fd then return -errno.EMFILE end
  self.fds[fd] = { description = description, cloexec = bit32.band(flags, O_CLOEXEC) ~= 0 }
  return fd
end

function M:write_fd(fd_number, data)
  local entry = self.fds[fd_number]
  if not entry or not entry.description.writable then return nil, "EBADF" end
  local fd = entry.description
  if fd.kind == "stdio" then write_handle(fd.handle, data); return #data end
  if fd.kind == "null" or fd.kind == "zero" then return #data end
  if fd.kind == "pipe_write" then
    if fd.pipe.readers == 0 then return nil, "EPIPE" end
    fd.pipe.data = fd.pipe.data .. data
    self:wake_pipe(fd.pipe)
    return #data
  end
  if fd.kind == "directory" then return nil, "EBADF" end
  if fd.kind ~= "file" then return nil, "EINVAL" end
  local current = fd.node.data
  local position = fd.append and (#current + 1) or fd.pos
  local padding = position > #current + 1 and string.rep("\0", position - #current - 1) or ""
  local before, after = current:sub(1, position - 1) .. padding, current:sub(position + #data)
  local replacement = before .. data .. after
  local ok, write_error = self.vfs:write_file(fd.path, replacement)
  if not ok then return nil, write_error or "EIO" end
  fd.node.data, fd.pos = replacement, position + #data
  return #data
end

function M:read_fd(fd_number, count)
  local entry = self.fds[fd_number]
  if not entry or not entry.description.readable then return nil, "EBADF" end
  local fd = entry.description
  if fd.kind == "file" then
    local data = fd.node.data:sub(fd.pos, fd.pos + count - 1)
    fd.pos = fd.pos + #data
    return data
  elseif fd.kind == "zero" then
    return string.rep("\0", count)
  elseif fd.kind == "null" then
    return ""
  elseif fd.kind == "directory" then
    return nil, "EISDIR"
  elseif fd.kind == "pipe_read" then
    if #fd.pipe.data > 0 then
      local data = fd.pipe.data:sub(1, count)
      fd.pipe.data = fd.pipe.data:sub(#data + 1)
      return data
    end
    if fd.pipe.writers == 0 then return "" end
    return nil, "EAGAIN"
  end
  return read_handle(fd, count)
end

local function inode_for(path)
  local hash = 5381
  for i = 1, #path do hash = bit32.band(hash * 33 + path:byte(i), 0xffffffff) end
  return hash == 0 and 1 or hash
end

function M:write_stat(address, info)
  self.memory:write(address, string.rep("\0", 144))
  self.memory:write_u64(address, u64.from_number(1))
  self.memory:write_u64(address + 8, u64.from_number(inode_for(info.path or "")))
  self.memory:write_u64(address + 16, u64.from_number(info.kind == "directory" and 2 or 1))
  local mode = info.kind == "directory" and 16877 or info.kind == "device" and 8630 or 33188
  self.memory:write_u32(address + 24, mode)
  self.memory:write_u64(address + 48, u64.from_number(info.size or 0))
  self.memory:write_u64(address + 56, u64.from_number(4096))
  self.memory:write_u64(address + 64, u64.from_number(math.ceil((info.size or 0) / 512)))
end

function M:stat_path(path, address, dirfd)
  local guest, path_error = self:path_for_at(dirfd, path)
  if not guest then return nil, path_error end
  local info, stat_error = self.vfs:stat(guest)
  if not info then return nil, stat_error end
  self:write_stat(address, info)
  return true
end

function M:getdents64(fd_number, address, count)
  local entry = self.fds[fd_number]
  if not entry then return nil, "EBADF" end
  local fd = entry.description
  if fd.kind ~= "directory" then return nil, "ENOTDIR" end
  if not fd.entries then
    local names, list_error = self.vfs:list(fd.path)
    if not names then return nil, list_error end
    fd.entries = { ".", ".." }
    for _, name in ipairs(names) do fd.entries[#fd.entries + 1] = name end
    fd.entry_index = 1
  end
  local written = 0
  while fd.entry_index <= #fd.entries do
    local name = fd.entries[fd.entry_index]
    local length = math.ceil((19 + #name + 1) / 8) * 8
    if written + length > count then break end
    local child = name == "." and fd.path or name == ".." and
      (fd.path == "/" and "/" or self.vfs:guest_path_from("..", fd.path))
      or self.vfs:guest_path_from(name, fd.path)
    local info = self.vfs:stat(child) or { kind = "file" }
    local target = address + written
    self.memory:write(target, string.rep("\0", length))
    self.memory:write_u64(target, u64.from_number(inode_for(child)))
    self.memory:write_u64(target + 8, u64.from_number(fd.entry_index))
    self.memory:write_u16(target + 16, length)
    self.memory:write8(target + 18, info.kind == "directory" and 4 or info.kind == "device" and 2 or 8)
    self.memory:write(target + 19, name .. "\0")
    written, fd.entry_index = written + length, fd.entry_index + 1
  end
  return written
end

local function copy_signal_actions(actions)
  local copied = {}
  for signal, action in pairs(actions) do
    copied[signal] = { u64.clone(action[1]), u64.clone(action[2]),
      u64.clone(action[3]), u64.clone(action[4]) }
  end
  return copied
end

local function mapping_text(memory)
  local out = {}
  for _, map in ipairs(memory:mappings()) do
    out[#out + 1] = string.format("%012x-%012x %s%s%sp 00000000 00:00 0\n", map.address,
      map.address + Memory.PAGE_SIZE, bit32.band(map.prot, 1) ~= 0 and "r" or "-",
      bit32.band(map.prot, 2) ~= 0 and "w" or "-", bit32.band(map.prot, 4) ~= 0 and "x" or "-")
  end
  return table.concat(out)
end

function M:update_proc_state()
  self.vfs.pid = self.pid
  self.vfs.maps_text = function() return mapping_text(self.memory) end
end

function M:fork_process(cpu, next_rip)
  local count = 0
  for _ in pairs(self.world.processes) do count = count + 1 end
  if self.world.max_processes and count >= self.world.max_processes then return nil, "EAGAIN" end
  local pid = self.world.next_pid
  self.world.next_pid = pid + 1
  local child_memory, child_vfs = self.memory:fork(), self.vfs:clone()
  local child = M.new(child_memory, child_vfs, { world = self.world, pid = pid, ppid = self.pid,
    brk = self.brk, mmap_base = self.mmap_next, seed = self.seed, trace = self.trace,
    instruction_trace = self.instruction_trace, io_limit = self.io_limit, skip_stdio = true })
  child.file_creation_mask = self.file_creation_mask
  child.signal_mask = u64.clone(self.signal_mask)
  child.signal_actions = copy_signal_actions(self.signal_actions)
  for fd, entry in pairs(self.fds) do
    entry.description.refs = entry.description.refs + 1
    child.fds[fd] = { description = entry.description, cloexec = entry.cloexec }
  end

  local child_cpu
  child_cpu = CPU.new(child_memory, { rip = next_rip, trace = self.instruction_trace,
    syscall = function(current, return_rip) return child:dispatch(current, return_rip) end })
  for reg = 0, 15 do
    child_cpu.regs[reg] = u64.clone(cpu.regs[reg])
    local xmm = cpu.xmm[reg]
    child_cpu.xmm[reg] = { xmm[1], xmm[2], xmm[3], xmm[4] }
  end
  child_cpu.rip, child_cpu.rflags = next_rip, cpu.rflags
  child_cpu.fs_base, child_cpu.gs_base = cpu.fs_base, cpu.gs_base
  result(child_cpu, 0)
  child:attach_cpu(child_cpu)
  child:update_proc_state()
  return pid
end

function M:read_string_vector(address, maximum)
  if address == 0 then return {} end
  local values, total = {}, 0
  for index = 0, (maximum or 4096) - 1 do
    local pointer = self.memory:read_u64(address + index * 8)
    if pointer[1] == 0 and pointer[2] == 0 then return values end
    if pointer[2] >= 0x00200000 then return nil, "EFAULT" end
    local value = self:cstring(u64.to_number(pointer), 4096)
    if not value then return nil, "EFAULT" end
    total = total + #value + 1
    if total > self.io_limit then return nil, "E2BIG" end
    values[#values + 1] = value
  end
  return nil, "E2BIG"
end

function M:execve(cpu, path, argv_address, env_address)
  local argv, argv_error = self:read_string_vector(argv_address)
  if not argv then return nil, argv_error end
  local environment, env_error = self:read_string_vector(env_address)
  if not environment then return nil, env_error end
  if #argv == 0 then argv[1] = path end
  local memory = Memory.new({ max_pages = self.memory.max_pages })
  local vfs = self.vfs:clone()
  local ok, loaded = pcall(ELF.load, memory, vfs, path, { argv = argv, env = environment })
  if not ok then
    if type(loaded) == "table" and loaded.class == "host_configuration" then
      return nil, loaded.code == "EACCES" and "EACCES" or "ENOENT"
    end
    return nil, type(loaded) == "table" and loaded.class == "resource_limit" and "ENOMEM" or "ENOEXEC"
  end

  local closing = {}
  for fd, entry in pairs(self.fds) do if entry.cloexec then closing[#closing + 1] = fd end end
  for _, fd in ipairs(closing) do self:close(fd) end
  self.memory, self.vfs = memory, vfs
  self.brk, self.mmap_next = 0x70000000, 0x71000000
  self.signal_actions = {}
  cpu.memory, cpu.regs, cpu.xmm = memory, {}, {}
  for reg = 0, 15 do cpu.regs[reg], cpu.xmm[reg] = u64.zero(), { 0, 0, 0, 0 } end
  cpu.rip, cpu.rflags, cpu.fs_base, cpu.gs_base, cpu.halted = loaded.entry, 2, 0, 0, false
  cpu:set_reg(4, u64.from_number(loaded.stack), 64)
  self:update_proc_state()
  return true
end

local function child_matches(parent, child, requested)
  return child.ppid == parent.pid and (requested == -1 or requested == child.pid)
end

function M:reap_child(child, status_address)
  if status_address ~= 0 then
    local status = child.term_signal_number or bit32.lshift(bit32.band(child.exit_code or 0, 0xff), 8)
    self.memory:write_u32(status_address, status)
  end
  self.world.processes[child.pid] = nil
  return child.pid
end

function M:wait4(cpu, requested, status_address, options)
  local matching, exited
  for _, child in pairs(self.world.processes) do
    if child_matches(self, child, requested) then
      matching = child
      if child.state == "exited" then exited = child; break end
    end
  end
  if exited then return self:reap_child(exited, status_address) end
  if not matching then return nil, "ECHILD" end
  if bit32.band(options, 1) ~= 0 then return 0 end
  self.state = "blocked"
  self.wait_request = { kind = "wait4", requested = requested, status = status_address, cpu = cpu }
  return false
end

function M:wake_waiters()
  for _, process in pairs(self.world.processes) do
    local request = process.wait_request
    if process.state == "blocked" and request and request.kind == "wait4" then
      local exited
      for _, child in pairs(self.world.processes) do
        if child.state == "exited" and child_matches(process, child, request.requested) then exited = child; break end
      end
      if exited then
        result(request.cpu, process:reap_child(exited, request.status))
        process.wait_request, process.state = nil, "runnable"
      end
    end
  end
end

function M:exit_process(code, signal_number)
  if self.state == "exited" then return end
  local descriptors = {}
  for fd in pairs(self.fds) do descriptors[#descriptors + 1] = fd end
  for _, fd in ipairs(descriptors) do self:close(fd) end
  self.exited, self.exit_code, self.term_signal_number = true, code, signal_number
  self.state = "exited"
  if self.cpu then self.cpu.halted = true end
  self:wake_waiters()
end

function M:create_pipe(address)
  local first = self:allocate_fd(0)
  if not first then return nil, "EMFILE" end
  self.fds[first] = { reserved = true }
  local second = self:allocate_fd(0)
  self.fds[first] = nil
  if not second then return nil, "EMFILE" end
  local pipe = { data = "", readers = 1, writers = 1 }
  self.fds[first] = { description = { kind = "pipe_read", pipe = pipe, readable = true, refs = 1 } }
  self.fds[second] = { description = { kind = "pipe_write", pipe = pipe, writable = true, refs = 1 } }
  self.memory:write_u32(address, first)
  self.memory:write_u32(address + 4, second)
  return true
end

function M:block_pipe_read(cpu, fd, address, count)
  self.state = "blocked"
  self.wait_request = { kind = "pipe_read", cpu = cpu, fd = fd, address = address, count = count,
    pipe = self.fds[fd].description.pipe }
end

function M:wake_pipe(pipe)
  for _, process in pairs(self.world.processes) do
    local request = process.wait_request
    if process.state == "blocked" and request and request.kind == "pipe_read" and request.pipe == pipe then
      local data, read_error = process:read_fd(request.fd, request.count)
      if data ~= nil then
        process.memory:write(request.address, data)
        result(request.cpu, #data)
        process.wait_request, process.state = nil, "runnable"
      elseif read_error ~= "EAGAIN" then
        result(request.cpu, -(errno[read_error] or errno.EIO))
        process.wait_request, process.state = nil, "runnable"
      end
    end
  end
end

function M:dispatch(cpu, next_rip)
  local nr = cpu.regs[0][1]
  local register_order, args = { 7, 6, 2, 10, 8, 9 }, { 0, 0, 0, 0, 0, 0 }
  for i = 1, syscall_argc[nr] or 0 do args[i] = number(cpu, register_order[i]) end
  local a1, a2, a3, a4, a5, a6 = args[1], args[2], args[3], args[4], args[5], args[6]
  self.syscalls = self.syscalls + 1
  self.world.syscalls = self.world.syscalls + 1
  if self.trace then self.trace({ number = nr, args = { a1, a2, a3, a4, a5, a6 } }) end

  if nr == 1 then -- write
    if a3 < 0 or a3 > self.io_limit then result(cpu, -errno.EINVAL)
    else
      local written, write_error = self:write_fd(a1, self.memory:read(a2, a3))
      result(cpu, written or -(errno[write_error] or errno.EIO))
    end
  elseif nr == 0 then -- read
    if a3 < 0 or a3 > self.io_limit then result(cpu, -errno.EINVAL)
    else
      local data, read_error = self:read_fd(a1, a3)
      if data == nil and read_error == "EAGAIN" and self.fds[a1]
          and self.fds[a1].description.kind == "pipe_read" then
        self:block_pipe_read(cpu, a1, a2, a3)
      elseif data == nil then result(cpu, -(errno[read_error] or errno.EIO))
      else self.memory:write(a2, data); result(cpu, #data) end
    end
  elseif nr == 2 or nr == 257 then
    local path_address, flags_value = nr == 2 and a1 or a2, nr == 2 and a2 or a3
    local path = self:cstring(path_address)
    result(cpu, path and self:open(path, flags_value, nr == 257 and a1 or AT_FDCWD) or -errno.EFAULT)
  elseif nr == 3 then
    local ok, close_error = self:close(a1)
    result(cpu, ok and 0 or -(errno[close_error] or errno.EBADF))
  elseif nr == 4 or nr == 6 then
    local path = self:cstring(a1)
    if not path then result(cpu, -errno.EFAULT)
    else
      local ok, stat_error = self:stat_path(path, a2, AT_FDCWD)
      result(cpu, ok and 0 or -(errno[stat_error] or errno.ENOENT))
    end
  elseif nr == 5 then
    local entry = self.fds[a1]
    if not entry then result(cpu, -errno.EBADF)
    else
      local fd = entry.description
      local size = fd.kind == "file" and #fd.node.data or 0
      self:write_stat(a2, { kind = fd.kind == "directory" and "directory" or
        (fd.kind == "null" or fd.kind == "zero") and "device" or "file", size = size,
        path = fd.path or ("/proc/self/fd/" .. tostring(a1)) })
      result(cpu, 0)
    end
  elseif nr == 8 then
    local entry = self.fds[a1]
    local fd = entry and entry.description
    if not fd then result(cpu, -errno.EBADF)
    elseif fd.kind ~= "file" then result(cpu, -errno.ESPIPE)
    else
      local offset = u64.to_signed_number(cpu.regs[6])
      local base = a3 == 0 and 1 or a3 == 1 and fd.pos or a3 == 2 and #fd.node.data + 1
      local position = base and base + offset or 0
      if not base or position < 1 then result(cpu, -errno.EINVAL)
      else fd.pos = position; result(cpu, fd.pos - 1) end
    end
  elseif nr == 20 then
    if a3 < 0 or a3 > 1024 then result(cpu, -errno.EINVAL)
    else
      local chunks, total = {}, 0
      for i = 0, a3 - 1 do
        local pointer_value = self.memory:read_u64(a2 + i * 16)
        local length_value = self.memory:read_u64(a2 + i * 16 + 8)
        if pointer_value[2] >= 0x00200000 or length_value[2] ~= 0 then
          total = self.io_limit + 1
          break
        end
        local pointer = u64.to_number(pointer_value)
        local length = length_value[1]
        if length > self.io_limit - total then total = self.io_limit + 1; break end
        chunks[#chunks + 1], total = self.memory:read(pointer, length), total + length
      end
      if total > self.io_limit then result(cpu, -errno.EINVAL)
      else
        local written, write_error = self:write_fd(a1, table.concat(chunks))
        result(cpu, written or -(errno[write_error] or errno.EIO))
      end
    end
  elseif nr == 21 then
    local path = self:cstring(a1)
    if not path then result(cpu, -errno.EFAULT)
    elseif bit32.band(a2, bit32.bnot(7)) ~= 0 then result(cpu, -errno.EINVAL)
    else
      local info, stat_error = self.vfs:stat(path)
      result(cpu, info and 0 or -(errno[stat_error] or errno.ENOENT))
    end
  elseif nr == 22 then
    local ok, pipe_error = self:create_pipe(a1)
    result(cpu, ok and 0 or -(errno[pipe_error] or errno.EMFILE))
  elseif nr == 32 then
    local fd, duplicate_error = self:duplicate(a1, 0)
    result(cpu, fd or -(errno[duplicate_error] or errno.EBADF))
  elseif nr == 33 then
    if a2 < 0 or a2 > 1048575 then result(cpu, -errno.EBADF)
    else
      local fd, duplicate_error = self:duplicate(a1, 0, a2, false)
      result(cpu, fd or -(errno[duplicate_error] or errno.EBADF))
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
    if a1 == 0 then result(cpu, self.brk)
    else
      local old_page = math.ceil(self.brk / Memory.PAGE_SIZE) * Memory.PAGE_SIZE
      local new_page = math.ceil(a1 / Memory.PAGE_SIZE) * Memory.PAGE_SIZE
      local ok = true
      if new_page > old_page then
        ok = pcall(function() self.memory:map(old_page, new_page - old_page,
          Memory.PROT_READ + Memory.PROT_WRITE) end)
      elseif new_page < old_page then
        ok = pcall(function() self.memory:unmap(new_page, old_page - new_page) end)
      end
      if ok then self.brk = a1 end
      result(cpu, self.brk)
    end
  elseif nr == 39 or nr == 186 then result(cpu, self.pid)
  elseif nr == 107 then result(cpu, 0)
  elseif nr == 110 then result(cpu, self.ppid)
  elseif nr == 57 or nr == 58 then
    local pid, fork_error = self:fork_process(cpu, next_rip or cpu.rip)
    result(cpu, pid or -(errno[fork_error] or errno.EAGAIN))
  elseif nr == 59 then
    local path = self:cstring(a1)
    if not path then result(cpu, -errno.EFAULT)
    else
      local ok, exec_error = self:execve(cpu, path, a2, a3)
      if ok then return true end
      result(cpu, -(errno[exec_error] or errno.ENOEXEC))
    end
  elseif nr == 61 then
    local waited, wait_error = self:wait4(cpu, a1, a2, a3)
    if waited ~= false then result(cpu, waited or -(errno[wait_error] or errno.ECHILD)) end
  elseif nr == 60 or nr == 231 then
    self:exit_process(bit32.band(a1, 0xff)); result(cpu, 0)
  elseif nr == 63 then
    local fields = { "Linux", "craftos", "6.6.0-craftos-blink", "#1", "x86_64", "(none)" }
    for i, value in ipairs(fields) do self.memory:write(a1 + (i - 1) * 65, value .. "\0" .. string.rep("\0", 64 - #value)) end
    result(cpu, 0)
  elseif nr == 79 then
    local cwd = self.vfs.cwd
    if #cwd + 1 > a2 then result(cpu, -errno.ERANGE) else self.memory:write(a1, cwd .. "\0"); result(cpu, a1) end
  elseif nr == 80 then
    local path = self:cstring(a1)
    if not path then result(cpu, -errno.EFAULT)
    else
      local ok, change_error = self.vfs:chdir(path)
      result(cpu, ok and 0 or -(errno[change_error] or errno.ENOENT))
    end
  elseif nr == 83 then
    local path = self:cstring(a1)
    if not path then result(cpu, -errno.EFAULT)
    else
      local ok, make_error = self.vfs:make_dir(path)
      result(cpu, ok and 0 or -(errno[make_error] or errno.EACCES))
    end
  elseif nr == 95 then
    local previous = self.file_creation_mask
    self.file_creation_mask = bit32.band(a1, 0x1ff)
    result(cpu, previous)
  elseif nr == 217 then
    if a3 < 24 or a3 > self.io_limit then result(cpu, -errno.EINVAL)
    else
      local written, directory_error = self:getdents64(a1, a2, a3)
      result(cpu, written or -(errno[directory_error] or errno.EIO))
    end
  elseif nr == 158 then
    if a1 == 0x1002 then cpu.fs_base = a2; result(cpu, 0)
    elseif a1 == 0x1001 then cpu.gs_base = a2; result(cpu, 0)
    elseif a1 == 0x1003 then self.memory:write_u64(a2, u64.from_number(cpu.fs_base)); result(cpu, 0)
    elseif a1 == 0x1004 then self.memory:write_u64(a2, u64.from_number(cpu.gs_base)); result(cpu, 0)
    else result(cpu, -errno.EINVAL) end
  elseif nr == 13 then
    if a1 < 1 or a1 > 64 or a4 ~= 8 or (a2 ~= 0 and (a1 == 9 or a1 == 19)) then
      result(cpu, -errno.EINVAL)
    else
      local previous = self.signal_actions[a1] or { u64.zero(), u64.zero(), u64.zero(), u64.zero() }
      if a3 ~= 0 then
        for i = 1, 4 do self.memory:write_u64(a3 + (i - 1) * 8, previous[i]) end
      end
      if a2 ~= 0 then
        self.signal_actions[a1] = { self.memory:read_u64(a2), self.memory:read_u64(a2 + 8),
          self.memory:read_u64(a2 + 16), self.memory:read_u64(a2 + 24) }
      end
      result(cpu, 0)
    end
  elseif nr == 14 then
    if a4 ~= 8 or a1 < 0 or a1 > 2 then result(cpu, -errno.EINVAL)
    else
      if a3 ~= 0 then self.memory:write_u64(a3, self.signal_mask) end
      if a2 ~= 0 then
        local requested = self.memory:read_u64(a2)
        if a1 == 0 then self.signal_mask = u64.bor(self.signal_mask, requested)
        elseif a1 == 1 then self.signal_mask = u64.band(self.signal_mask, u64.bnot(requested))
        else self.signal_mask = requested end
        local unblockable = u64.bor(u64.shl(u64.one(), 8), u64.shl(u64.one(), 18))
        self.signal_mask = u64.band(self.signal_mask, u64.bnot(unblockable))
      end
      result(cpu, 0)
    end
  elseif nr == 16 then
    local entry = self.fds[a1]
    local fd = entry and entry.description
    if not fd then result(cpu, -errno.EBADF)
    elseif fd.kind ~= "stdio" then result(cpu, -errno.ENOTTY)
    elseif a2 == 0x5401 then -- TCGETS
      self.memory:write(a3, string.rep("\0", 44)); result(cpu, 0)
    elseif a2 == 0x5413 then -- TIOCGWINSZ
      local width, height = 51, 19
      if type(term) == "table" and type(term.getSize) == "function" then width, height = term.getSize() end
      self.memory:write_u16(a3, height); self.memory:write_u16(a3 + 2, width)
      self.memory:write_u16(a3 + 4, 0); self.memory:write_u16(a3 + 6, 0); result(cpu, 0)
    elseif a2 == 0x5414 then result(cpu, 0) -- TIOCSWINSZ
    else result(cpu, -errno.ENOTTY) end
  elseif nr == 72 then
    local entry = self.fds[a1]
    if not entry then result(cpu, -errno.EBADF)
    elseif a2 == 0 then
      local fd, duplicate_error = self:duplicate(a1, a3)
      result(cpu, fd or -(errno[duplicate_error] or errno.EMFILE))
    elseif a2 == 1 then result(cpu, entry.cloexec and 1 or 0)
    elseif a2 == 2 then entry.cloexec = bit32.band(a3, 1) ~= 0; result(cpu, 0)
    elseif a2 == 3 then result(cpu, entry.description.status_flags or 0)
    elseif a2 == 4 then
      entry.description.append = bit32.band(a3, O_APPEND) ~= 0
      entry.description.status_flags = bit32.bor(bit32.band(entry.description.status_flags or 0, O_ACCMODE),
        bit32.band(a3, O_APPEND))
      result(cpu, 0)
    elseif a2 == 1030 then
      local fd, duplicate_error = self:duplicate(a1, a3, nil, true)
      result(cpu, fd or -(errno[duplicate_error] or errno.EMFILE))
    else result(cpu, -errno.EINVAL) end
  elseif nr == 262 then
    local path = self:cstring(a2)
    if not path then result(cpu, -errno.EFAULT)
    elseif bit32.band(a4, bit32.bnot(0x1100)) ~= 0 then result(cpu, -errno.EINVAL)
    else
      local ok, stat_error = self:stat_path(path, a3, a1)
      result(cpu, ok and 0 or -(errno[stat_error] or errno.ENOENT))
    end
  elseif nr == 218 then result(cpu, self.pid)
  elseif nr == 273 then result(cpu, 0)
  elseif nr == 228 then
    local ms = type(os.epoch) == "function" and os.epoch("utc") or math.floor(os.time() * 1000)
    local sec = math.floor(ms / 1000); self.memory:write_u64(a2, u64.from_number(sec)); self.memory:write_u64(a2 + 8, u64.from_number((ms % 1000) * 1000000)); result(cpu, 0)
  elseif nr == 318 then
    if a2 < 0 or a2 > self.io_limit then result(cpu, -errno.EINVAL)
    else for i = 0, a2 - 1 do self.memory:write8(a1 + i, self:random_byte()) end; result(cpu, a2) end
  elseif nr == 41 then result(cpu, a1 == 1 and -errno.ENOSYS or -errno.EAFNOSUPPORT)
  else result(cpu, -errno.ENOSYS) end
end

M.errno = errno
return M
