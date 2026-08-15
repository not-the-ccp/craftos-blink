local Memory = require("craftos_blink.memory")
local VFS = require("craftos_blink.vfs")
local ELF = require("craftos_blink.elf")
local CPU = require("craftos_blink.cpu")
local Kernel = require("craftos_blink.kernel")
local platform = require("craftos_blink.platform")
local u64 = require("craftos_blink.u64")

local M = { VERSION = "0.1.0-alpha.6" }

local profiles = {
  ["craftos-pc"] = { memory = 256 * 1024 * 1024, processes = 64, slice = 10000 },
  ingame = { memory = 16 * 1024 * 1024, processes = 8, slice = 2000 },
}

local function environment_list(env)
  local result = {}
  if #env > 0 then for _, value in ipairs(env) do result[#result + 1] = value end
  else for key, value in pairs(env) do result[#result + 1] = key .. "=" .. tostring(value) end end
  table.sort(result)
  return result
end

function M.run(config)
  assert(type(config) == "table", "config table required")
  assert(type(config.program) == "string", "config.program is required")
  local profile = profiles[config.profile or "craftos-pc"]
  assert(profile, "profile must be 'craftos-pc' or 'ingame'")
  local memory_limit = config.memory_limit or profile.memory
  local memory = Memory.new({ max_pages = math.floor(memory_limit / Memory.PAGE_SIZE) })
  local vfs = VFS.new({ root = config.root or ".", cwd = config.cwd or "/", adapter = config.fs })
  vfs:install_virtual_nodes(1)
  local instruction_trace = config.trace_instruction
  local syscall_trace = config.trace_syscall
  local kernel = Kernel.new(memory, vfs, { stdin = config.stdin, stdout = config.stdout,
    stderr = config.stderr, seed = config.seed, trace = syscall_trace,
    instruction_trace = instruction_trace, max_processes = profile.processes })
  local loaded = ELF.load(memory, vfs, config.program, { argv = config.argv or { config.program },
    env = environment_list(config.environment or {}), base = config.base, stack_size = config.stack_size })
  local cpu
  cpu = CPU.new(memory, { rip = loaded.entry, trace = instruction_trace,
    syscall = function(c, next_rip) return kernel:dispatch(c, next_rip) end })
  cpu:set_reg(4, u64.from_number(loaded.stack), 64)
  kernel:attach_cpu(cpu)
  kernel:update_proc_state()

  local started = platform.now_ms()
  local slice_started, slice_count = started, 0
  local instruction_limit = config.instruction_limit or math.huge
  local instructions, root_fault = 0, nil
  local signal_numbers = { SIGHUP = 1, SIGINT = 2, SIGILL = 4, SIGABRT = 6, SIGFPE = 8,
    SIGKILL = 9, SIGSEGV = 11, SIGPIPE = 13, SIGTERM = 15 }
  local ok, fault = pcall(function()
    while kernel.state ~= "exited" and instructions < instruction_limit do
      local runnable = {}
      for pid, process in pairs(kernel.world.processes) do
        if process.state == "runnable" and process.cpu and not process.cpu.halted then
          runnable[#runnable + 1] = pid
        end
      end
      table.sort(runnable)
      if #runnable == 0 then error({ class = "resource_limit", resource = "scheduler_deadlock" }, 0) end
      for _, pid in ipairs(runnable) do
        if kernel.state == "exited" or instructions >= instruction_limit then break end
        local process = kernel.world.processes[pid]
        if process and process.state == "runnable" and not process.cpu.halted then
          local step_ok, step_fault = pcall(process.cpu.step, process.cpu)
          instructions, slice_count = instructions + 1, slice_count + 1
          if not step_ok then
            if type(step_fault) ~= "table" or step_fault.class ~= "guest_fault" then error(step_fault, 0) end
            process:exit_process(128 + (signal_numbers[step_fault.signal] or 0),
              signal_numbers[step_fault.signal] or 0)
            if process == kernel then root_fault = step_fault end
          end
          local now = platform.now_ms()
          if slice_count >= (config.slice_instructions or profile.slice) or now - slice_started >= 50 then
            local terminated = config.yield and config.yield() or platform.cooperative_yield()
            if terminated == "terminate" then
              root_fault = { class = "guest_fault", signal = "SIGTERM", code = "SI_USER",
                address = kernel.cpu.rip }
              kernel:exit_process(143, 15)
            end
            slice_count, slice_started = 0, platform.now_ms()
          end
        end
      end
    end
    if kernel.state ~= "exited" then error({ class = "resource_limit", resource = "instructions" }, 0) end
  end)
  local elapsed = math.floor(platform.now_ms() - started)
  if not ok then
    if type(fault) == "table" and fault.class == "guest_fault" then
      return { exit_code = nil, signal = fault.signal, fault = fault, instructions = cpu.instructions,
        syscalls = kernel.syscalls, elapsed_ms = elapsed }
    end
    error(fault, 0)
  end
  if root_fault then
    return { exit_code = nil, signal = root_fault.signal, fault = root_fault, instructions = instructions,
      syscalls = kernel.world.syscalls, elapsed_ms = elapsed }
  end
  return { exit_code = kernel.exit_code or 0, signal = nil, instructions = instructions,
    syscalls = kernel.world.syscalls, elapsed_ms = elapsed }
end

M.profiles = profiles
return M
