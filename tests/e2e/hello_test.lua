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

local original_fs, original_read = _G.fs, _G.read
local cc_input = { "help", "exit" }
local cc_input_index, cc_output = 0, {}
_G.fs = {}
_G.read = function()
  cc_input_index = cc_input_index + 1
  return cc_input[cc_input_index]
end
local cc_minish = blink.run({ root = ".", program = "/build/fixtures/minish",
  stdout = function(data) cc_output[#cc_output + 1] = data end,
  instruction_limit = 300 })
_G.fs, _G.read = original_fs, original_read
t.eq(cc_minish.exit_code, 0, "ComputerCraft terminal guest result")
t.eq(table.concat(cc_output), table.concat({
  "minish$ built-ins: echo TEXT, uname, help, exit\n",
  "minish$ bye from x86-64\n",
}), "ComputerCraft terminal guest output")
