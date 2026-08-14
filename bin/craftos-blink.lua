#!/usr/bin/env lua5.2
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)/bin/craftos%-blink.lua$") or "."
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. root .. "/?.lua;" .. package.path

local function usage(status)
  io.stderr:write("usage: craftos-blink [options] PROGRAM [ARG...]\n",
    "  --root DIR             guest filesystem root\n",
    "  --cwd DIR              guest working directory\n",
    "  --env NAME=VALUE       append guest environment entry\n",
    "  --profile NAME         craftos-pc or ingame\n",
    "  --seed NUMBER          deterministic random seed\n",
    "  --instruction-limit N  maximum guest instructions\n",
    "  --memory-limit N       maximum guest bytes\n",
    "  --trace-instructions   trace decoded instructions\n",
    "  --trace-syscalls       trace syscall numbers\n")
  os.exit(status)
end

local config = { environment = {}, argv = {} }
local i = 1
while i <= #arg do
  local value = arg[i]
  if value == "--help" or value == "-h" then usage(0)
  elseif value == "--root" or value == "--cwd" or value == "--profile" or value == "--seed"
      or value == "--instruction-limit" or value == "--memory-limit" or value == "--env" then
    i = i + 1; if not arg[i] then usage(2) end
    if value == "--root" then config.root = arg[i]
    elseif value == "--cwd" then config.cwd = arg[i]
    elseif value == "--profile" then config.profile = arg[i]
    elseif value == "--seed" then config.seed = tonumber(arg[i])
    elseif value == "--instruction-limit" then config.instruction_limit = tonumber(arg[i])
    elseif value == "--memory-limit" then config.memory_limit = tonumber(arg[i])
    else config.environment[#config.environment + 1] = arg[i] end
  elseif value == "--trace-instructions" then
    config.trace_instruction = function(e) io.stderr:write(string.format("%012x  %s\n", e.rip, e.mnemonic)) end
  elseif value == "--trace-syscalls" then
    config.trace_syscall = function(e) io.stderr:write("syscall ", tostring(e.number), "\n") end
  elseif value:sub(1, 1) == "-" then usage(2)
  else
    config.program = value
    for j = i, #arg do config.argv[#config.argv + 1] = arg[j] end
    break
  end
  i = i + 1
end
if not config.program then usage(2) end

local blink = require("craftos_blink")
local ok, result = pcall(blink.run, config)
if not ok then
  if type(result) == "table" then
    io.stderr:write("craftos-blink: ", result.class or "error", ": ", result.code or result.detail or "unknown", "\n")
  else io.stderr:write("craftos-blink: ", tostring(result), "\n") end
  os.exit(125)
end
if result.signal then io.stderr:write("craftos-blink: guest terminated by ", result.signal, "\n"); os.exit(128) end
os.exit(result.exit_code)
