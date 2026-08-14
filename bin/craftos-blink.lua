#!/usr/bin/env lua5.2
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)/bin/craftos%-blink.lua$") or "."
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. root .. "/?.lua;" .. package.path
os.exit(require("craftos_blink.cli").main(arg))
