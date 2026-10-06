package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local captured_command
package.preload["tohsakawrt.core"] = function()
    return {
        get_uci = function(_, _, _, default) return default end,
        exec = function(command) captured_command = command; return "OK" end
    }
end
package.preload["nixio"] = function() return { fs = { stat = function() return true end } } end
package.preload["luci.jsonc"] = function() return {} end

local modem = require("tohsakawrt.modem")
assert(modem.at("AT+TEST", 2) == "OK", "AT call must preserve core.exec return value")
assert(captured_command:find("timeout 2 ", 1, true), "AT command must use the requested timeout")
assert(captured_command:find("kill -9 $__p", 1, true), "AT command must include the watchdog fallback")
assert(captured_command:find("command -v timeout", 1, true), "AT command must guard optional timeout availability")

local function replace_all(value, needle, replacement)
    local out = {}
    local cursor = 1
    while true do
        local first, last = value:find(needle, cursor, true)
        if not first then
            out[#out + 1] = value:sub(cursor)
            break
        end
        out[#out + 1] = value:sub(cursor, first - 1)
        out[#out + 1] = replacement
        cursor = last + 1
    end
    return table.concat(out)
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function now_ms()
    local pipe = assert(io.popen("date +%s%N", "r"))
    local value = tonumber(pipe:read("*l"))
    pipe:close()
    assert(value, "date +%s%N must provide a numeric timestamp")
    return value / 1000000
end

local inner = "sh /usr/share/modem/modem_at.sh /dev/ttyUSB3 'AT+TEST' 2>/dev/null"
local normal_command = replace_all(captured_command, "command -v timeout", "false")
normal_command = replace_all(normal_command, inner, "echo hi")
local started = now_ms()
local normal_pipe = assert(io.popen("sh -c " .. shell_quote(normal_command) .. " 2>/dev/null", "r"))
local normal_output = normal_pipe:read("*a")
normal_pipe:close()
local normal_ms = now_ms() - started
assert(normal_output:find("hi", 1, true), "immediate fallback command must preserve normal stdout")
assert(normal_ms < 500, string.format("immediate fallback must finish below 500 ms (measured %.0f ms)", normal_ms))
print(string.format("Measured immediate fallback: %.0f ms (< 500 ms)", normal_ms))

local timeout_command = replace_all(captured_command, "command -v timeout", "false")
timeout_command = replace_all(timeout_command, inner, "sleep 10")
started = now_ms()
local timeout_pipe = assert(io.popen("sh -c " .. shell_quote(timeout_command) .. " 2>/dev/null", "r"))
timeout_pipe:read("*a")
timeout_pipe:close()
local timeout_ms = now_ms() - started
assert(timeout_ms >= 1500 and timeout_ms <= 6000,
    string.format("sleep fallback must be killed between 1500 and 6000 ms (measured %.0f ms)", timeout_ms))
print(string.format("Measured timeout fallback: %.0f ms (1500–6000 ms)", timeout_ms))

print("PASS: modem AT timeout fallback closes stdout promptly and kills slow commands")
