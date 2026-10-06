package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local commands = {}
package.preload["tohsakawrt.core"] = function()
    return {
        exec_line = function(command)
            commands[#commands + 1] = command
            return "OK"
        end,
        exec = function() return "" end
    }
end
package.preload["luci.jsonc"] = function() return { parse = function() return {} end } end

local clash = require("tohsakawrt.clash")
assert(clash.direct_add("example.com") == "OK", "valid target must be passed to the helper")
assert(commands[1] == "/usr/bin/tohsaka-direct add 'example.com' 2>/dev/null",
    "accepted target must be passed as a single-quoted shell argument")

local malicious = "$(id) `id`'"
assert(clash.direct_add(malicious) == "ERROR:invalid_target",
    "command substitution, backticks, and quotes must fail target validation")
assert(#commands == 1, "rejected direct_add target must not execute a command")
for _, target in ipairs({ "example domain", "example.com;id", "$(id)", "`id`", "a'b" }) do
    assert(clash.direct_add(target) == "ERROR:invalid_target", "direct_add must reject target: " .. target)
    assert(clash.direct_del(target) == "ERROR:invalid_target", "direct_del must reject target: " .. target)
end
assert(#commands == 1, "invalid add/delete targets must never reach exec_line")
assert(clash.direct_del("2001:db8::1/64") == "OK", "valid IPv6 CIDR target must be accepted")
assert(commands[2] == "/usr/bin/tohsaka-direct del '2001:db8::1/64' 2>/dev/null",
    "valid CIDR target must be passed as a single-quoted shell argument")

print("PASS: clash direct targets are shell-quoted and invalid targets never execute")
