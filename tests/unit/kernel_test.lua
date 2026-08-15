local t = require("testlib")
local Memory = require("craftos_blink.memory")
local VFS = require("craftos_blink.vfs")
local CPU = require("craftos_blink.cpu")
local Kernel = require("craftos_blink.kernel")
local u64 = require("craftos_blink.u64")

local memory = Memory.new()
local vfs = VFS.new({ root = "." })
local cpu = CPU.new(memory)
local kernel = Kernel.new(memory, vfs)

-- No-argument syscalls must not inspect unrelated scratch registers.
cpu:set_reg(0, u64.from_number(110), 64)
cpu:set_reg(8, u64.new(0x12345678, 0x87654321), 64)
kernel:dispatch(cpu)
t.eq(u64.to_number(cpu.regs[0]), 0, "getppid")

-- Linux commonly passes MAP_ANONYMOUS with an fd and offset of -1.
cpu:set_reg(0, u64.from_number(9), 64)
cpu:set_reg(7, u64.zero(), 64)
cpu:set_reg(6, u64.from_number(4096), 64)
cpu:set_reg(2, u64.from_number(3), 64)
cpu:set_reg(10, u64.from_number(0x22), 64)
cpu:set_reg(8, u64.from_signed(-1), 64)
cpu:set_reg(9, u64.from_signed(-1), 64)
kernel:dispatch(cpu)
t.eq(u64.to_number(cpu.regs[0]), 0x71000000, "anonymous mmap with signed arguments")

cpu:set_reg(0, u64.from_number(12), 64)
cpu:set_reg(7, u64.from_number(0x70001000), 64)
for _, reg in ipairs({ 6, 2, 10, 8, 9 }) do cpu:set_reg(reg, u64.zero(), 64) end
kernel:dispatch(cpu)
t.eq(u64.to_number(cpu.regs[0]), 0x70001000, "brk grows")
memory:write8(0x70000000, 0x5a)
t.eq(memory:read8(0x70000000), 0x5a, "brk maps writable heap")

memory:map(0x72000000, 4096, Memory.PROT_READ + Memory.PROT_WRITE)
memory:write_u64(0x72000000, u64.from_number(0x1234))
cpu:set_reg(0, u64.from_number(13), 64)
cpu:set_reg(7, u64.from_number(2), 64)
cpu:set_reg(6, u64.from_number(0x72000000), 64)
cpu:set_reg(2, u64.zero(), 64)
cpu:set_reg(10, u64.from_number(8), 64)
kernel:dispatch(cpu)
t.eq(u64.to_number(cpu.regs[0]), 0, "rt_sigaction stores state")
t.eq(u64.to_number(kernel.signal_actions[2][1]), 0x1234, "signal handler state")

cpu:set_reg(0, u64.from_number(16), 64)
cpu:set_reg(7, u64.from_number(1), 64)
cpu:set_reg(6, u64.from_number(0x5413), 64)
cpu:set_reg(2, u64.from_number(0x72000100), 64)
kernel:dispatch(cpu)
t.eq(u64.to_number(cpu.regs[0]), 0, "terminal window-size ioctl")
t.eq(memory:read_u16(0x72000100), 19, "default terminal rows")

-- File-descriptor and filesystem syscalls are exercised through the x86-64 ABI,
-- not only through kernel helpers. This adapter deliberately models directories
-- separately so openat/chdir/getdents cannot accidentally pass as flat files.
local files = { ["root/existing"] = "abc", ["root/dir/child"] = "child" }
local directories = { ["root"] = true, ["root/dir"] = true }
local function parent(path) return path:match("^(.*)/[^/]+$") end
local fs_adapter = {
  combine = function(a, b) return a:gsub("/$", "") .. "/" .. b:gsub("^/", "") end,
  read = function(path) return files[path], files[path] and nil or "ENOENT" end,
  write = function(path, data)
    if not directories[parent(path)] then return nil, "ENOENT" end
    files[path] = data
    return true
  end,
  exists = function(path) return files[path] ~= nil or directories[path] ~= nil end,
  is_dir = function(path) return directories[path] or false end,
  make_dir = function(path)
    if files[path] or directories[path] then return nil, "EEXIST" end
    if not directories[parent(path)] then return nil, "ENOENT" end
    directories[path] = true
    return true
  end,
  list = function(path)
    if not directories[path] then return nil, "ENOTDIR" end
    local prefix, seen, out = path .. "/", {}, {}
    for name in pairs(files) do
      local child = name:sub(1, #prefix) == prefix and name:sub(#prefix + 1):match("^[^/]+")
      if child and not seen[child] then seen[child], out[#out + 1] = true, child end
    end
    for name in pairs(directories) do
      local child = name:sub(1, #prefix) == prefix and name:sub(#prefix + 1):match("^[^/]+")
      if child and not seen[child] then seen[child], out[#out + 1] = true, child end
    end
    table.sort(out)
    return out
  end,
}

local fs_memory = Memory.new()
fs_memory:map(0x73000000, 8192, Memory.PROT_READ + Memory.PROT_WRITE)
local fs_vfs = VFS.new({ root = "root", adapter = fs_adapter })
fs_vfs:install_virtual_nodes(7)
local fs_cpu = CPU.new(fs_memory)
local fs_kernel = Kernel.new(fs_memory, fs_vfs)
local arg_registers = { 7, 6, 2, 10, 8, 9 }
local string_next = 0x73000000
local function guest_string(value)
  local address = string_next
  fs_memory:write(address, value .. "\0")
  string_next = string_next + #value + 1
  return address
end
local function syscall(nr, ...)
  fs_cpu:set_reg(0, u64.from_number(nr), 64)
  local arguments = { ... }
  for index, reg in ipairs(arg_registers) do
    local value = arguments[index] or 0
    fs_cpu:set_reg(reg, value < 0 and u64.from_signed(value) or u64.from_number(value), 64)
  end
  fs_kernel:dispatch(fs_cpu)
  return fs_cpu.regs[0][2] >= 0xffe00000 and u64.to_signed_number(fs_cpu.regs[0])
    or u64.to_number(fs_cpu.regs[0])
end

local created = guest_string("/created")
local fd = syscall(2, created, 0x42, 420) -- O_CREAT | O_RDWR
t.eq(fd, 3, "open creates lowest available descriptor")
fs_memory:write(0x73000400, "hello")
t.eq(syscall(1, fd, 0x73000400, 5), 5, "write returns persisted byte count")
t.eq(files["root/created"], "hello", "write persists through VFS")
t.eq(syscall(8, fd, 0, 0), 0, "lseek rewinds file")
local duplicate = syscall(32, fd)
t.eq(duplicate, 4, "dup allocates next descriptor")
t.eq(syscall(0, duplicate, 0x73000500, 2), 2, "dup reads shared description")
t.eq(syscall(0, fd, 0x73000510, 3), 3, "dup shares file offset")
t.eq(fs_memory:read(0x73000500, 2), "he", "first shared-offset read")
t.eq(fs_memory:read(0x73000510, 3), "llo", "second shared-offset read")
t.eq(syscall(3, fd), 0, "close original descriptor")
t.eq(syscall(8, duplicate, 0, 0), 0, "duplicate survives original close")

local append_fd = syscall(2, created, 0x401, 0) -- O_APPEND | O_WRONLY
fs_memory:write(0x73000420, "!")
t.eq(syscall(1, append_fd, 0x73000420, 1), 1, "append write")
t.eq(files["root/created"], "hello!", "append ignores current offset")
t.eq(syscall(8, duplicate, 0, 2), 6, "open descriptions share underlying file identity")
local trunc_fd = syscall(2, created, 0x201, 0) -- O_TRUNC | O_WRONLY
t.eq(files["root/created"], "", "open truncates writable file")
t.eq(syscall(8, duplicate, 0, 2), 0, "truncate is visible through existing descriptions")
t.eq(syscall(3, trunc_fd), 0, "close truncated file")
t.eq(syscall(3, trunc_fd), -9, "double close returns EBADF")

t.eq(syscall(8, duplicate, 4, 0), 4, "seek beyond end")
fs_memory:write(0x73000430, "x")
t.eq(syscall(1, duplicate, 0x73000430, 1), 1, "sparse write")
t.eq(files["root/created"], string.rep("\0", 4) .. "x", "sparse write zero-fills gap")

fs_memory:write(0x73000440, "ab")
fs_memory:write(0x73000450, "cd")
fs_memory:write_u64(0x73000b00, u64.from_number(0x73000440))
fs_memory:write_u64(0x73000b08, u64.from_number(2))
fs_memory:write_u64(0x73000b10, u64.from_number(0x73000450))
fs_memory:write_u64(0x73000b18, u64.from_number(2))
t.eq(syscall(20, append_fd, 0x73000b00, 2), 4, "writev concatenates vectors")
t.eq(files["root/created"], string.rep("\0", 4) .. "xabcd", "writev persists once")
t.eq(syscall(1, append_fd, 0x73000440, -1), -22, "oversized write count is rejected")

local existing = guest_string("/existing")
t.eq(syscall(4, existing, 0x73000600), 0, "stat regular file")
t.eq(fs_memory:read_u32(0x73000600 + 24), 33188, "stat regular mode")
t.eq(u64.to_number(fs_memory:read_u64(0x73000600 + 48)), 3, "stat file size")
t.eq(syscall(262, -100, existing, 0x730006a0, 0), 0, "newfstatat AT_FDCWD")
t.eq(syscall(21, existing, 0), 0, "access existing path")
t.eq(syscall(21, guest_string("/missing"), 0), -2, "access missing path")

local new_dir = guest_string("/newdir")
t.eq(syscall(83, new_dir, 493), 0, "mkdir creates directory")
t.eq(syscall(80, new_dir), 0, "chdir enters directory")
t.eq(syscall(79, 0x73000700, 32), 0x73000700, "getcwd returns buffer")
t.eq(fs_memory:read(0x73000700, 8), "/newdir\0", "getcwd writes new cwd")
t.eq(syscall(95, 0x3f), 0x12, "umask returns previous mask")
t.eq(syscall(95, 0x12), 0x3f, "umask stores masked state")
t.eq(syscall(107), 0, "geteuid is root inside guest")

local directory = guest_string("/dir")
local directory_fd = syscall(2, directory, 0x10000, 0)
t.truthy(directory_fd >= 3, "open O_DIRECTORY")
local relative = guest_string("child")
local child_fd = syscall(257, directory_fd, relative, 0, 0)
t.truthy(child_fd >= 3, "openat resolves relative to directory descriptor")
t.eq(syscall(0, child_fd, 0x73000740, 5), 5, "openat child read")
t.eq(fs_memory:read(0x73000740, 5), "child", "openat child contents")
local cloexec_fd = syscall(257, directory_fd, relative, 0x80000, 0)
t.eq(syscall(72, cloexec_fd, 1, 0), 1, "O_CLOEXEC initializes descriptor flag")
t.truthy(syscall(217, directory_fd, 0x73000800, 512) > 0, "getdents64 emits directory records")
t.eq(syscall(217, directory_fd, 0x73000800, 512), 0, "getdents64 reaches end of directory")

t.eq(syscall(33, child_fd, 20), 20, "dup2 uses requested descriptor")
t.eq(syscall(3, child_fd), 0, "close dup2 source")
t.eq(syscall(8, 20, 0, 0), 0, "dup2 target retains shared description")
t.eq(syscall(72, 20, 1, 0), 0, "fcntl F_GETFD")
t.eq(syscall(72, 20, 2, 1), 0, "fcntl F_SETFD")
t.eq(syscall(72, 20, 1, 0), 1, "fcntl descriptor flags are per descriptor")

local dev_zero = guest_string("/dev/zero")
local zero_fd = syscall(2, dev_zero, 0, 0)
t.eq(syscall(0, zero_fd, 0x73000a00, 8), 8, "/dev/zero read count")
t.eq(fs_memory:read(0x73000a00, 8), string.rep("\0", 8), "/dev/zero bytes")
local dev_null = guest_string("/dev/null")
local null_fd = syscall(2, dev_null, 1, 0)
t.eq(syscall(1, null_fd, 0x73000400, 5), 5, "/dev/null discards writes")

local fault_read_fd = syscall(2, existing, 0, 0)
t.eq(syscall(0, fault_read_fd, 0x74000000, 2), -14, "read invalid buffer returns EFAULT")
t.eq(syscall(0, fault_read_fd, 0x73000e00, 3), 3, "EFAULT read does not advance offset")
t.eq(fs_memory:read(0x73000e00, 3), "abc", "read after EFAULT starts at original offset")
local fault_path = guest_string("/faultfile")
local fault_write_fd = syscall(2, fault_path, 0x42, 420)
t.eq(syscall(1, fault_write_fd, 0x74000000, 2), -14, "write invalid buffer returns EFAULT")
t.eq(files["root/faultfile"], "", "EFAULT write has no filesystem effect")
t.eq(syscall(2, guest_string("../../escape"), 0, 0), -13, "sandbox escape returns EACCES")

local trace_events = {}
fs_kernel.trace = function(event) trace_events[#trace_events + 1] = event end
t.eq(syscall(39), 1, "traced getpid")
t.eq(trace_events[1].phase, "enter", "syscall trace enter phase")
t.eq(trace_events[1].pid, 1, "syscall trace pid")
t.eq(trace_events[1].number, 39, "syscall trace number")
t.eq(trace_events[2].phase, "exit", "syscall trace exit phase")
t.eq(trace_events[2].result, 1, "syscall trace result")
fs_kernel.trace = nil

-- Process objects share open-file descriptions and pipes while keeping COW
-- memory and wait state distinct. Drive the handlers at syscall return RIPs so
-- a forked child cannot accidentally re-execute the fork instruction.
fs_kernel:attach_cpu(fs_cpu)
fs_kernel:update_proc_state()
local function set_process_syscall(process, nr, arguments)
  process.cpu:set_reg(0, u64.from_number(nr), 64)
  arguments = arguments or {}
  for index, reg in ipairs(arg_registers) do
    local value = arguments[index] or 0
    process.cpu:set_reg(reg, value < 0 and u64.from_signed(value) or u64.from_number(value), 64)
  end
end
local function process_result(process)
  return process.cpu.regs[0][2] >= 0xffe00000 and u64.to_signed_number(process.cpu.regs[0])
    or u64.to_number(process.cpu.regs[0])
end

set_process_syscall(fs_kernel, 22, { 0x73000c00 })
fs_kernel:dispatch(fs_cpu, 0x2000)
t.eq(process_result(fs_kernel), 0, "pipe syscall")
local pipe_read, pipe_write = fs_memory:read_u32(0x73000c00), fs_memory:read_u32(0x73000c04)
t.truthy(pipe_read ~= pipe_write, "pipe returns distinct descriptors")
set_process_syscall(fs_kernel, 0, { pipe_read, 0x73000c20, 0 })
fs_kernel:dispatch(fs_cpu, 0x2001)
t.eq(process_result(fs_kernel), 0, "zero-length pipe read never blocks")

fs_memory:write8(0x73000d00, 0x11)
set_process_syscall(fs_kernel, 57)
fs_kernel:dispatch(fs_cpu, 0x123456)
local child_pid = process_result(fs_kernel)
local child = fs_kernel.world.processes[child_pid]
t.truthy(child ~= nil, "fork registers child process")
t.eq(child.ppid, fs_kernel.pid, "fork child parent pid")
t.eq(child.cpu.rip, 0x123456, "fork child resumes after syscall")
t.eq(process_result(child), 0, "fork child result is zero")
child.memory:write8(0x73000d00, 0x22)
t.eq(fs_memory:read8(0x73000d00), 0x11, "fork memory is copy-on-write")
t.eq(child.memory:read8(0x73000d00), 0x22, "child sees private COW write")
t.eq(child.fds[pipe_read].description, fs_kernel.fds[pipe_read].description,
  "fork shares open-file descriptions")

set_process_syscall(child, 0, { pipe_read, 0x73000d10, 4 })
child:dispatch(child.cpu, 0x123458)
t.eq(child.state, "blocked", "empty pipe read blocks child")
fs_memory:write(0x73000d20, "pipe")
set_process_syscall(fs_kernel, 1, { pipe_write, 0x73000d20, 4 })
fs_kernel:dispatch(fs_cpu, 0x2002)
t.eq(child.state, "runnable", "pipe write wakes reader")
t.eq(process_result(child), 4, "woken pipe read result")
t.eq(child.memory:read(0x73000d10, 4), "pipe", "pipe transfers bytes")

child:exit_process(7)
set_process_syscall(fs_kernel, 61, { child_pid, 0x73000d40, 0, 0 })
fs_kernel:dispatch(fs_cpu, 0x2004)
t.eq(process_result(fs_kernel), child_pid, "wait4 reaps exited child")
t.eq(fs_memory:read_u32(0x73000d40), 7 * 256, "wait4 encodes exit status")
t.eq(fs_kernel.world.processes[child_pid], nil, "wait4 removes zombie")

set_process_syscall(fs_kernel, 57)
fs_kernel:dispatch(fs_cpu, 0x223344)
local waiting_pid = process_result(fs_kernel)
local waiting_child = fs_kernel.world.processes[waiting_pid]
set_process_syscall(fs_kernel, 61, { waiting_pid, 0x73000d50, 0, 0 })
fs_kernel:dispatch(fs_cpu, 0x2006)
t.eq(fs_kernel.state, "blocked", "wait4 blocks while child runs")
waiting_child:exit_process(3)
t.eq(fs_kernel.state, "runnable", "child exit wakes waiting parent")
t.eq(process_result(fs_kernel), waiting_pid, "blocked wait4 receives child pid")
t.eq(fs_memory:read_u32(0x73000d50), 3 * 256, "blocked wait4 status")
