local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)/tests/run.lua$") or "."
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" ..
  root .. "/tests/?.lua;" .. package.path

local tests = {
  "unit.u64_test",
  "unit.memory_test",
  "unit.flags_test",
  "unit.decoder_test",
  "unit.cpu_test",
  "unit.vfs_test",
  "unit.elf_test",
  "unit.kernel_test",
  "e2e.hello_test",
  "unit.registry_test",
}

for _, name in ipairs(tests) do
  io.write("[TEST] ", name, "\n")
  local ok, err = pcall(require, name)
  if not ok then
    io.stderr:write("[FAIL] ", name, ": ", tostring(err), "\n")
    os.exit(1)
  end
end

local t = require("testlib")
io.write(string.format("[PASS] %d assertions in %d files\n", t.count, #tests))
