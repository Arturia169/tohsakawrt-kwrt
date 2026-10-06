-- 出口切换：Lua 侧只负责"参数映射 + 错误码归一化"，真正的路由操作只保留 shell 一份实现
-- 注意：失败回滚的断言在 tests/test_uplink_switch.sh 内（含"恢复 5G metric 1 默认路由"用例）。
package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;" .. package.path

local calls, script_reply

local function stub_core()
    calls = {}
    package.loaded["tohsakawrt.system"] = nil
    package.loaded["tohsakawrt.core"] = nil
    for _, name in ipairs({ "tohsakawrt.modem", "tohsakawrt.clash", "tohsakawrt.esim", "tohsakawrt.tg" }) do
        package.preload[name] = function() return {} end
    end
    -- system.lua 头部会加载这两个模块：luci.jsonc 与 nixio 只存在于路由器上，
    -- 补桩件后本用例在任何机器（含 CI）都能跑。
    package.preload["luci.jsonc"] = function()
        return { parse = function() return nil end, stringify = function() return "{}" end }
    end
    package.preload["nixio"] = function()
        return { fs = { stat = function() return nil end }, nanosleep = function() end }
    end
    package.preload["tohsakawrt.core"] = function()
        return {
            init = function() end,
            exec = function() return "" end,
            exec_line = function(cmd)
                calls[#calls + 1] = tostring(cmd)
                return script_reply
            end,
            log = function() end,
            get_uci = function(_, _, _, default) return default end,
            set_uci = function() end,
            set_cached_state = function(key) calls[#calls + 1] = "cache_clear:" .. tostring(key) end,
            get_state = function(_, default) return default end
        }
    end
end

local function loaded()
    stub_core()
    return require("tohsakawrt.system")
end

-- 1) 参数映射：5g/usb0 -> 5g；wan/eth0 -> wan；成功后清公网 IP 缓存
local sys = loaded()
script_reply = "SUCCESS_5G"
assert(sys.switch_uplink("5g") == "SUCCESS_5G", "5g 应返回 SUCCESS_5G")
assert(calls[1] and calls[1]:find("/usr/bin/tohsakawrt-uplink 5g", 1, true),
    "5g 必须调用 shell 唯一实现，实际：" .. tostring(calls[1]))
assert(calls[2] == "cache_clear:cache_pub_ip", "切换成功后应清除公网 IP 缓存")

sys = loaded()
script_reply = "SUCCESS_WAN"
assert(sys.switch_uplink("eth0") == "SUCCESS_WAN", "eth0 应返回 SUCCESS_WAN")
assert(calls[1] and calls[1]:find("/usr/bin/tohsakawrt-uplink wan", 1, true),
    "eth0 必须映射成 wan 参数，实际：" .. tostring(calls[1]))

-- 2) 带中文后缀的错误码必须归一化成裸码（机器人是按裸码精确比较的）
sys = loaded()
script_reply = "ERROR_5G_NO_IP: 5G 接口 usb0 未获取到 IP 或网关"
assert(sys.switch_uplink("5g") == "ERROR_5G_NO_IP", "带后缀的 ERROR_5G_NO_IP 必须归一化")

sys = loaded()
script_reply = "ERROR_SWITCH_FAILED: 添加 5G 优先路由失败"
assert(sys.switch_uplink("5g") == "ERROR_SWITCH_FAILED", "带后缀的 ERROR_SWITCH_FAILED 必须归一化")

sys = loaded()
script_reply = "ALREADY_WAN"
assert(sys.switch_uplink("wan") == "ALREADY_WAN", "ALREADY_* 应原样返回")

-- 3) 脚本没有输出时必须按失败处理，不能让机器人显示空白
sys = loaded()
script_reply = ""
assert(sys.switch_uplink("5g") == "ERROR_SWITCH_FAILED", "脚本无输出必须按失败处理")

-- 4) 非法目标不得调用脚本
sys = loaded()
script_reply = "SUCCESS_5G"
assert(sys.switch_uplink("lte") == "INVALID_TARGET", "非法目标应返回 INVALID_TARGET")
assert(#calls == 0, "非法目标不得调用切换脚本")

print("PASS: 出口切换只保留 shell 一份实现，Lua 侧只做参数映射与错误码归一化")
