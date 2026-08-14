local t = require("testlib")
local f = require("craftos_blink.flags")

t.eq(f.logic({0, 0}, 64), f.ZF + f.PF, "zero flags")
t.truthy(bit32.band(f.logic({0x80, 0}, 8), f.SF) ~= 0, "sign flag")
t.truthy(f.condition(4, f.ZF), "JE")
t.truthy(f.condition(5, 0), "JNE")
t.truthy(f.condition(12, f.SF), "JL")

