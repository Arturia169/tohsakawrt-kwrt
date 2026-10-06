package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

-- 覆盖最后一笔 eSIM 欠账：
--   ① 任务号必须唯一（同秒内多次生成也不重复），且带 6 位随机后缀
--   ② cleanup_jobs 必须用"保留窗口"删除过期任务文件，且 uci 可覆盖该窗口
--   ③ job_exists 必须能识别 .spec / .txt 任一个存在

local commands, uci_reads = {}, {}
local uci_values = {}

package.preload["tohsakawrt.core"] = function()
    return {
        init = function() end,
        log = function() end,
        exec = function(cmd) commands[#commands + 1] = cmd; return "" end,
        get_uci = function(_, _, option, default)
            uci_reads[#uci_reads + 1] = option
            if uci_values[option] ~= nil then return uci_values[option] end
            return default
        end,
        get_state = function(_, default) return default end,
        set_state = function() end,
    }
end
package.preload["tohsakawrt.modem"] = function() return {} end
-- bot_common 会 require 这几个模块；其中 system.lua 硬依赖路由器专属的 nixio，
-- 非路由器环境（N100 / CI）必须桩件化，否则载入失败
package.preload["tohsakawrt.system"] = function() return {} end
package.preload["tohsakawrt.clash"] = function() return {} end
package.preload["nixio"] = function()
    return { fs = { stat = function() return nil end } }
end
package.preload["luci.jsonc"] = function()
    return { parse = function() return nil end, stringify = function() return "{}" end }
end

local esim = require("tohsakawrt.esim")
local bot_esim = require("tohsakawrt.bot_esim")

-- ① 任务号唯一 + 格式
local seen = {}
for i = 1, 50 do
    local id = bot_esim.new_job_id()
    assert(type(id) == "string" and id:match("^%d+$"), "任务号必须是纯数字字符串，实际 " .. tostring(id))
    assert(#id >= 16, "任务号应包含 秒(10位) + 6 位随机，实际长度 " .. #id)
    assert(not seen[id], "同一秒内 50 次生成出现重复任务号: " .. id)
    seen[id] = true
end

-- ② cleanup_jobs：默认保留窗口与 uci 覆盖
commands = {}
esim.cleanup_jobs()
local cmd = commands[#commands]
assert(cmd and cmd:find("esim-job-*", 1, true), "清理命令应针对 esim-job-* 文件")
assert(cmd:find("-mmin +1440", 1, true), "默认保留窗口应为 1440 分钟，实际命令: " .. tostring(cmd))
assert(cmd:find("-exec rm -f", 1, true), "清理命令应删除过期文件，实际: " .. tostring(cmd))

commands = {}
esim.cleanup_jobs(120)
assert(commands[#commands]:find("-mmin +120", 1, true), "显式传入的保留窗口应生效")

commands = {}
uci_values["esim_job_retain_minutes"] = "2880"
esim.cleanup_jobs()
assert(commands[#commands]:find("-mmin +2880", 1, true), "uci 里的保留窗口应生效")

commands = {}
uci_values["esim_job_retain_minutes"] = "5"      -- 过小应被夹到下限 60
esim.cleanup_jobs()
assert(commands[#commands]:find("-mmin +60", 1, true), "过小的保留窗口应被夹到 60 分钟")

commands = {}
uci_values["esim_job_retain_minutes"] = "999999"  -- 过大应被夹到上限 10080
esim.cleanup_jobs()
assert(commands[#commands]:find("-mmin +10080", 1, true), "过大的保留窗口应被夹到 10080 分钟")
uci_values["esim_job_retain_minutes"] = nil

-- ③ job_exists：不存在 → false；写了 .txt 或 .spec → true
local probe = "9" .. string.format("%06d", math.random(0, 999999))
assert(esim.job_exists(probe) == false, "未创建的任务号不应被认为已占用")

os.execute("mkdir -p /tmp/tohsakawrt/state")
local f = io.open("/tmp/tohsakawrt/state/esim-job-" .. probe .. ".txt", "w")
assert(f, "测试需要能写 /tmp/tohsakawrt/state")
f:write("test"); f:close()
assert(esim.job_exists(probe) == true, "已有 .txt 的任务号应被认为已占用")
os.remove("/tmp/tohsakawrt/state/esim-job-" .. probe .. ".txt")
assert(esim.job_exists(probe) == false, "删除后应重新可用")

print("PASS: 任务号唯一（含 6 位随机）、cleanup_jobs 保留窗口可配且带边界夹取、job_exists 判定正确")
