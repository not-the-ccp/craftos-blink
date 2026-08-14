local t = require("testlib")
local blink = require("craftos_blink")

local output = {}
local result = blink.run({
  root = ".",
  program = "/build/fixtures/hello",
  argv = { "/build/fixtures/hello" },
  environment = { "LANG=C" },
  stdout = { write = function(data) output[#output + 1] = data end },
  instruction_limit = 100,
})
t.eq(table.concat(output), "hello from x86-64\n")
t.eq(result.exit_code, 0)
t.eq(result.signal, nil)
t.eq(result.instructions, 8)
t.eq(result.syscalls, 2)

