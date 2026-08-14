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

local arithmetic = blink.run({ root = ".", program = "/build/fixtures/arithmetic",
  instruction_limit = 100 })
t.eq(arithmetic.exit_code, 42, "arithmetic guest result")

local input = { "help\n", "echo hello from Minecraft\n", "uname\n", "exit\n" }
local input_index, minish_output = 0, {}
local minish = blink.run({ root = ".", program = "/build/fixtures/minish",
  stdin = function()
    input_index = input_index + 1
    return input[input_index]
  end,
  stdout = function(data) minish_output[#minish_output + 1] = data end,
  instruction_limit = 500 })
t.eq(minish.exit_code, 0, "interactive guest result")
t.eq(table.concat(minish_output), table.concat({
  "minish$ built-ins: echo TEXT, uname, help, exit\n",
  "minish$ hello from Minecraft\n",
  "minish$ Linux craftos 6.6.0-craftos-blink x86_64\n",
  "minish$ bye from x86-64\n",
}), "interactive guest output")
