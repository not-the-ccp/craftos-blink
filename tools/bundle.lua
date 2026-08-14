local root, output, mode = assert(arg[1]), assert(arg[2]), arg[3] or "api"
local modules = {
  "u64", "memory", "flags", "registry", "decoder", "cpu", "vfs", "elf",
  "kernel", "platform", "init", "cli",
}
local out = assert(io.open(output, "wb"))
out:write("-- CraftOS Blink standalone bundle; generated, do not edit.\n")
out:write("local preload = package.preload\n")
for _, short in ipairs(modules) do
  local name = "craftos_blink." .. short
  local path = root .. "/src/craftos_blink/" .. short .. ".lua"
  local h = assert(io.open(path, "rb")); local source = h:read("*a"); h:close()
  out:write("preload[", string.format("%q", name), "] = assert(load(", string.format("%q", source),
    ", ", string.format("%q", "@" .. name), "))\n")
end
out:write("preload['craftos_blink'] = function() return require('craftos_blink.init') end\n")
if mode == "api" then out:write("return require('craftos_blink')\n")
else out:write("return require('craftos_blink.cli').main(arg or {})\n") end
out:close()

