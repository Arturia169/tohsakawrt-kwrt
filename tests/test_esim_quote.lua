package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local test_id = "quote-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local spec_path = "/tmp/tohsakawrt/state/esim-job-" .. test_id .. ".spec"
local result_path = "/tmp/tohsakawrt/state/esim-job-" .. test_id .. ".txt"
local captured_command

local function cleanup()
    os.remove(spec_path)
    os.remove(result_path)
end

package.preload["tohsakawrt.core"] = function()
    return {
        init = function() end,
        log = function() end,
        exec = function() return "" end,
        get_uci = function(_, _, _, default) return default end,
        set_state = function() end,
        get_state = function(_, default) return default end
    }
end
package.preload["tohsakawrt.modem"] = function() return {} end
package.preload["tohsakawrt.tg"] = function()
    return { send_msg = function() end, edit_msg = function() end }
end
package.preload["luci.jsonc"] = function()
    return {
        parse = function()
            return { type = "lpa", payload = { code = 1, message = "test failure" } }
        end
    }
end

os.execute("mkdir -p /tmp/tohsakawrt/state")
local f = assert(io.open(spec_path, "w"))
f:write("download\n$(id) `id`\ntest profile\n0\nx$(id)y\n0")
f:close()

local original_popen = io.popen
io.popen = function(command)
    captured_command = command
    return {
        read = function() return '{"type":"lpa","payload":{"code":1}}' end,
        close = function() end
    }
end
local ok, err = pcall(function()
    require("tohsakawrt.esim").worker(test_id)
end)
io.popen = original_popen
cleanup()
assert(ok, "worker must complete with the captured lpac command: " .. tostring(err))
assert(captured_command == "lpac profile download -a '$(id) `id`' -c 'x$(id)y' 2>/dev/null",
    "worker must pass the activation code and confirmation code as shell-quoted arguments")

print("PASS: eSIM worker shell-quotes activation and confirmation codes")
