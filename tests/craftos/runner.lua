-- CraftOS executes startup scripts as rom/startup.lua, so paths are relative
-- to the ROM directory rather than the computer root.
package.path = "../blink/src/?.lua;../blink/src/?/init.lua;../blink/?.lua;" .. package.path

local blink = require("craftos_blink")
local output = {}
local ok, result = pcall(blink.run, {
  root = "blink",
  program = "/build/fixtures/hello",
  argv = { "/build/fixtures/hello" },
  environment = { "LANG=C" },
  profile = "craftos-pc",
  stdout = { write = function(data) output[#output + 1] = data end },
  instruction_limit = 100,
})

if not ok then
  print("CRAFTOS-BLINK-FAIL", type(result) == "table" and result.class or tostring(result))
  os.shutdown(1)
elseif table.concat(output) ~= "hello from x86-64\n" or result.exit_code ~= 0 then
  print("CRAFTOS-BLINK-FAIL", "bad result")
  os.shutdown(1)
else
  print("CRAFTOS-BLINK-PASS", result.instructions, result.syscalls)
  os.shutdown(0)
end
