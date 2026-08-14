local u64 = require("craftos_blink.u64")
local Memory = require("craftos_blink.memory")

local M = {}
local PAGE = Memory.PAGE_SIZE

local function elf_error(code, detail)
  error({ class = "malformed_elf", code = code, detail = detail }, 0)
end

local function u16(s, p)
  local a, b = s:byte(p, p + 1); if not b then elf_error("truncated") end
  return a + b * 256
end

local function u32(s, p)
  local a, b, c, d = s:byte(p, p + 3); if not d then elf_error("truncated") end
  return a + b * 256 + c * 65536 + d * 16777216
end

local function number64(s, p)
  local v = u64.from_le(s, p, 8)
  local ok, n = pcall(u64.to_number, v)
  if not ok then elf_error("value_out_of_range", u64.hex(v)) end
  return n
end

local function align_down(v) return v - v % PAGE end
local function align_up(v) return math.ceil(v / PAGE) * PAGE end

function M.parse(data)
  if #data < 64 then elf_error("truncated_header") end
  if data:sub(1, 4) ~= "\127ELF" then elf_error("bad_magic") end
  if data:byte(5) ~= 2 then elf_error("not_elf64") end
  if data:byte(6) ~= 1 then elf_error("not_little_endian") end
  if data:byte(7) ~= 1 then elf_error("bad_version") end
  local header = {
    type = u16(data, 17), machine = u16(data, 19), version = u32(data, 21),
    entry = number64(data, 25), phoff = number64(data, 33), shoff = number64(data, 41),
    flags = u32(data, 49), ehsize = u16(data, 53), phentsize = u16(data, 55),
    phnum = u16(data, 57), shentsize = u16(data, 59), shnum = u16(data, 61),
  }
  if header.machine ~= 62 then elf_error("wrong_machine", header.machine) end
  if header.type ~= 2 and header.type ~= 3 then elf_error("unsupported_type", header.type) end
  if header.ehsize ~= 64 or header.phentsize ~= 56 then elf_error("bad_header_size") end
  if header.phoff + header.phentsize * header.phnum > #data then elf_error("truncated_program_headers") end
  header.program_headers = {}
  for i = 0, header.phnum - 1 do
    local p = header.phoff + i * header.phentsize + 1
    local ph = { type = u32(data, p), flags = u32(data, p + 4),
      offset = number64(data, p + 8), vaddr = number64(data, p + 16),
      paddr = number64(data, p + 24), filesz = number64(data, p + 32),
      memsz = number64(data, p + 40), align = number64(data, p + 48) }
    if ph.filesz > ph.memsz then elf_error("filesz_exceeds_memsz", i) end
    if ph.offset + ph.filesz > #data then elf_error("truncated_segment", i) end
    header.program_headers[#header.program_headers + 1] = ph
  end
  return header
end

local function segment_prot(flags)
  local prot = 0
  if bit32.band(flags, 4) ~= 0 then prot = prot + Memory.PROT_READ end
  if bit32.band(flags, 2) ~= 0 then prot = prot + Memory.PROT_WRITE end
  if bit32.band(flags, 1) ~= 0 then prot = prot + Memory.PROT_EXEC end
  return prot
end

local function map_image(memory, data, elf, base)
  local mapped, phdr = {}, nil
  for _, ph in ipairs(elf.program_headers) do
    if ph.type == 1 and ph.memsz > 0 then
      local start = align_down(base + ph.vaddr)
      local finish = align_up(base + ph.vaddr + ph.memsz)
      for address = start, finish - PAGE, PAGE do
        if not memory.pages[math.floor(address / PAGE)] then
          memory:map(address, PAGE, Memory.PROT_READ + Memory.PROT_WRITE)
          mapped[#mapped + 1] = { address = address, prot = segment_prot(ph.flags) }
        end
      end
      if ph.filesz > 0 then memory:write(base + ph.vaddr, data:sub(ph.offset + 1, ph.offset + ph.filesz)) end
      if elf.phoff >= ph.offset and elf.phoff + elf.phentsize * elf.phnum <= ph.offset + ph.filesz then
        phdr = base + ph.vaddr + (elf.phoff - ph.offset)
      end
    end
  end
  for _, page in ipairs(mapped) do memory:protect(page.address, PAGE, page.prot) end
  return phdr
end

local function write_stack(memory, top, argv, env, auxv, random)
  local sp = top
  local function bytes(value)
    sp = sp - #value
    memory:write(sp, value)
    return sp
  end
  local execfn = bytes((argv[1] or "") .. "\0")
  local platform = bytes("x86_64\0")
  local random_address = bytes(random)
  local envp = {}
  for i = #env, 1, -1 do envp[i] = bytes(env[i] .. "\0") end
  local argp = {}
  for i = #argv, 1, -1 do argp[i] = bytes(argv[i] .. "\0") end
  sp = sp - sp % 16
  auxv[#auxv + 1] = { 25, random_address }
  auxv[#auxv + 1] = { 31, execfn }
  auxv[#auxv + 1] = { 15, platform }
  auxv[#auxv + 1] = { 0, 0 }
  for i = #auxv, 1, -1 do
    sp = sp - 16; memory:write_u64(sp, u64.from_number(auxv[i][1])); memory:write_u64(sp + 8, u64.from_number(auxv[i][2]))
  end
  sp = sp - 8; memory:write_u64(sp, u64.zero())
  for i = #envp, 1, -1 do sp = sp - 8; memory:write_u64(sp, u64.from_number(envp[i])) end
  sp = sp - 8; memory:write_u64(sp, u64.zero())
  for i = #argp, 1, -1 do sp = sp - 8; memory:write_u64(sp, u64.from_number(argp[i])) end
  sp = sp - 8; memory:write_u64(sp, u64.from_number(#argv))
  return sp
end

function M.load(memory, vfs, path, options)
  options = options or {}
  local data, err = vfs:read_file(path)
  if not data then error({ class = "host_configuration", code = err, path = path }, 0) end
  if data:sub(1, 2) == "#!" then
    if (options.shebang_depth or 0) >= 4 then elf_error("shebang_recursion") end
    local line = data:match("^#!([^\r\n]+)")
    if not line then elf_error("bad_shebang") end
    local interpreter, optional = line:match("^%s*(%S+)%s*(.-)%s*$")
    if not interpreter then elf_error("bad_shebang") end
    local old = options.argv or { path }
    local argv = { interpreter }
    if optional ~= "" then argv[#argv + 1] = optional end
    argv[#argv + 1] = path
    for i = 2, #old do argv[#argv + 1] = old[i] end
    local nested = {}
    for key, value in pairs(options) do nested[key] = value end
    nested.argv, nested.shebang_depth = argv, (options.shebang_depth or 0) + 1
    local result = M.load(memory, vfs, interpreter, nested)
    result.script, result.script_interpreter = path, interpreter
    return result
  end
  local elf = M.parse(data)
  local base = elf.type == 3 and (options.base or 0x40000000) or 0
  local phdr = map_image(memory, data, elf, base)
  local interp
  for _, ph in ipairs(elf.program_headers) do
    if ph.type == 3 then interp = data:sub(ph.offset + 1, ph.offset + ph.filesz):gsub("%z.*", "") end
  end
  local entry, interp_base = base + elf.entry, 0
  if interp then
    local loader_data, loader_err = vfs:read_file(interp)
    if not loader_data then error({ class = "host_configuration", code = loader_err,
      path = interp, detail = "ELF interpreter missing from guest root" }, 0) end
    local loader = M.parse(loader_data)
    interp_base = options.interp_base or 0x60000000
    map_image(memory, loader_data, loader, interp_base)
    entry = interp_base + loader.entry
  end
  local stack_top = options.stack_top or 0x7fffffff0000
  local stack_size = options.stack_size or 8 * 1024 * 1024
  memory:map(stack_top - stack_size, stack_size, Memory.PROT_READ + Memory.PROT_WRITE)
  local random = options.random_bytes or "CraftOSBlinkSeed"
  local auxv = {
    { 3, phdr or (base + elf.phoff) }, { 4, elf.phentsize }, { 5, elf.phnum },
    { 6, PAGE }, { 7, interp_base }, { 9, base + elf.entry }, { 11, 1000 },
    { 12, 1000 }, { 13, 1000 }, { 14, 1000 }, { 23, 0 },
  }
  local sp = write_stack(memory, stack_top, options.argv or { path }, options.env or {}, auxv, random)
  vfs.executable = path
  return { entry = entry, program_entry = base + elf.entry, stack = sp, base = base,
    interp = interp, interp_base = interp_base, elf = elf }
end

return M
