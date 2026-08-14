local M = {}

local function stderr_write(...)
  local values = { ... }
  if io and io.stderr then
    for _, value in ipairs(values) do io.stderr:write(tostring(value)) end
  elseif type(printError) == "function" then
    printError(table.concat(values))
  end
end

local function usage()
  stderr_write("usage: craftos-blink [options] PROGRAM [ARG...]\n",
    "  --root DIR             guest filesystem root\n",
    "  --cwd DIR              guest working directory\n",
    "  --env NAME=VALUE       append guest environment entry\n",
    "  --profile NAME         craftos-pc or ingame\n",
    "  --seed NUMBER          deterministic random seed\n",
    "  --instruction-limit N  maximum guest instructions\n",
    "  --memory-limit N       maximum guest bytes\n",
    "  --trace-instructions   trace decoded instructions\n",
    "  --trace-syscalls       trace syscall numbers\n")
end

function M.main(arguments)
  local config = { environment = {}, argv = {} }
  local i = 1
  while i <= #arguments do
    local value = arguments[i]
    if value == "--help" or value == "-h" then usage(); return 0
    elseif value == "--root" or value == "--cwd" or value == "--profile" or value == "--seed"
        or value == "--instruction-limit" or value == "--memory-limit" or value == "--env" then
      i = i + 1; if not arguments[i] then usage(); return 2 end
      if value == "--root" then config.root = arguments[i]
      elseif value == "--cwd" then config.cwd = arguments[i]
      elseif value == "--profile" then config.profile = arguments[i]
      elseif value == "--seed" then config.seed = tonumber(arguments[i])
      elseif value == "--instruction-limit" then config.instruction_limit = tonumber(arguments[i])
      elseif value == "--memory-limit" then config.memory_limit = tonumber(arguments[i])
      else config.environment[#config.environment + 1] = arguments[i] end
    elseif value == "--trace-instructions" then
      config.trace_instruction = function(e) stderr_write(string.format("%012x  %s\n", e.rip, e.mnemonic)) end
    elseif value == "--trace-syscalls" then
      config.trace_syscall = function(e) stderr_write("syscall ", tostring(e.number), "\n") end
    elseif value:sub(1, 1) == "-" then usage(); return 2
    else
      config.program = value
      for j = i, #arguments do config.argv[#config.argv + 1] = arguments[j] end
      break
    end
    i = i + 1
  end
  if not config.program then usage(); return 2 end

  local blink = require("craftos_blink")
  local ok, result = pcall(blink.run, config)
  if not ok then
    if type(result) == "table" then
      stderr_write("craftos-blink: ", result.class or "error", ": ", result.code or result.detail or "unknown", "\n")
    else stderr_write("craftos-blink: ", tostring(result), "\n") end
    return 125
  end
  if result.signal then stderr_write("craftos-blink: guest terminated by ", result.signal, "\n"); return 128 end
  return result.exit_code
end

return M

