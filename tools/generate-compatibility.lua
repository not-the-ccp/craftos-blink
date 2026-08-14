local root = arg[1] or "."
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path
local registry = require("craftos_blink.registry")

local function write(path, data)
  local h = assert(io.open(root .. "/" .. path, "wb")); h:write(data); h:close()
end

local markdown = {
  "# Compatibility\n\n",
  "This file is generated from `src/craftos_blink/registry.lua`. A feature is supported only when its status is `implemented`; planned entries are not advertised by CPUID.\n\n",
  "## Instructions\n\n| Instruction | Encoding | Class | Status |\n|---|---|---|---|\n",
}
for _, item in ipairs(registry.instructions) do
  markdown[#markdown + 1] = string.format("| %s | `%s` | %s | **%s** |\n", item.name, item.encoding, item.class, item.status)
end
markdown[#markdown + 1] = "\n## Linux x86-64 syscalls\n\n| Number | Name | Status |\n|---:|---|---|\n"
for _, item in ipairs(registry.syscalls) do
  markdown[#markdown + 1] = string.format("| %s | `%s` | **%s** |\n", tostring(item.number), item.name, item.status)
end
markdown[#markdown + 1] = [[

## Deliberate boundaries

- AF_INET and AF_INET6 are unavailable because standard CC:Tweaked exposes no raw TCP/UDP socket API. AF_UNIX remains planned.
- JIT, BIOS, real mode, PC hardware, and the blinkenlights debugger UI are not part of this userspace port.
- x87 and vector/extended instruction families are listed as planned until their differential suites pass. Blink's reduced x87 long-double precision boundary will be retained and documented when enabled.
- The in-game profile uses only standard ComputerCraft APIs and requires attached storage for a glibc guest root.
]]
write("docs/compatibility.md", table.concat(markdown))

local function quote(value) return string.format("%q", tostring(value)) end
local json = { "{\n  \"upstream_blink\": \"f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580\",\n  \"instructions\": [\n" }
for i, item in ipairs(registry.instructions) do
  json[#json + 1] = string.format("    {\"name\": %s, \"encoding\": %s, \"class\": %s, \"status\": %s}%s\n",
    quote(item.name), quote(item.encoding), quote(item.class), quote(item.status), i < #registry.instructions and "," or "")
end
json[#json + 1] = "  ],\n  \"syscalls\": [\n"
for i, item in ipairs(registry.syscalls) do
  json[#json + 1] = string.format("    {\"number\": %s, \"name\": %s, \"status\": %s}%s\n",
    type(item.number) == "number" and tostring(item.number) or quote(item.number), quote(item.name), quote(item.status),
    i < #registry.syscalls and "," or "")
end
json[#json + 1] = "  ]\n}\n"
write("generated/compatibility.json", table.concat(json))

