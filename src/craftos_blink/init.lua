local Memory = require("craftos_blink.memory")
local VFS = require("craftos_blink.vfs")
local ELF = require("craftos_blink.elf")
local CPU = require("craftos_blink.cpu")
local Kernel = require("craftos_blink.kernel")
local platform = require("craftos_blink.platform")
local u64 = require("craftos_blink.u64")

local M = { VERSION = "0.1.0-dev" }

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
    stderr = config.stderr, seed = config.seed, trace = syscall_trace })
  local loaded = ELF.load(memory, vfs, config.program, { argv = config.argv or { config.program },
    env = environment_list(config.environment or {}), base = config.base, stack_size = config.stack_size })
  local cpu
  cpu = CPU.new(memory, { rip = loaded.entry, trace = instruction_trace,
    syscall = function(c) kernel:dispatch(c) end })
  cpu:set_reg(4, u64.from_number(loaded.stack), 64)
  vfs.maps_text = function()
    local out = {}
    for _, map in ipairs(memory:mappings()) do
      out[#out + 1] = string.format("%012x-%012x %s%s%sp 00000000 00:00 0\n", map.address,
        map.address + Memory.PAGE_SIZE, bit32.band(map.prot, 1) ~= 0 and "r" or "-",
        bit32.band(map.prot, 2) ~= 0 and "w" or "-", bit32.band(map.prot, 4) ~= 0 and "x" or "-")
    end
    return table.concat(out)
  end

  local started = platform.now_ms()
  local slice_started, slice_count = started, 0
  local instruction_limit = config.instruction_limit or math.huge
  local ok, fault = pcall(function()
    while not cpu.halted and cpu.instructions < instruction_limit do
      cpu:step(); slice_count = slice_count + 1
      local now = platform.now_ms()
      if slice_count >= (config.slice_instructions or profile.slice) or now - slice_started >= 50 then
        local terminated = config.yield and config.yield() or platform.cooperative_yield()
        if terminated == "terminate" then
          error({ class = "guest_fault", signal = "SIGTERM", code = "SI_USER", address = cpu.rip }, 0)
        end
        slice_count, slice_started = 0, platform.now_ms()
      end
    end
    if not cpu.halted then error({ class = "resource_limit", resource = "instructions" }, 0) end
  end)
  local elapsed = math.floor(platform.now_ms() - started)
  if not ok then
    if type(fault) == "table" and fault.class == "guest_fault" then
      return { exit_code = nil, signal = fault.signal, fault = fault, instructions = cpu.instructions,
        syscalls = kernel.syscalls, elapsed_ms = elapsed }
    end
    error(fault, 0)
  end
  return { exit_code = kernel.exit_code or 0, signal = nil, instructions = cpu.instructions,
    syscalls = kernel.syscalls, elapsed_ms = elapsed }
end

M.profiles = profiles
return M

