local t = require("testlib")
local registry = require("craftos_blink.registry")

local seen_instructions, seen_syscalls = {}, {}
for _, item in ipairs(registry.instructions) do
  t.truthy(not seen_instructions[item.name], "duplicate instruction " .. item.name)
  seen_instructions[item.name] = true
  t.truthy(item.status == "implemented" or item.status == "planned" or item.status == "fault")
end
for _, item in ipairs(registry.syscalls) do
  local key = tostring(item.number)
  t.truthy(not seen_syscalls[key], "duplicate syscall " .. key)
  seen_syscalls[key] = true
end

