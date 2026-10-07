package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path
-- tg.lua 在非路由器环境需要这两个桩件（它 require luci.jsonc 与 nixio）
package.preload["luci.jsonc"] = function()
    return { parse = function() return nil end, stringify = function() return "{}" end }
end
package.preload["nixio"] = function() return {} end
package.preload["tohsakawrt.core"] = function()
    return { init=function() end, log=function() end, exec=function() return "" end,
        exec_line=function() return "" end, get_uci=function(_,_,_,d) return d end,
        get_state=function(_,d) return d end, set_state=function() end }
end
local tg = require("tohsakawrt.tg")

local function flatten(kb)
    local out = {}
    for _, row in ipairs(kb or {}) do for _, b in ipairs(row) do out[#out+1] = b end end
    return out
end
local function has(kb, pred)
    for _, b in ipairs(flatten(kb)) do if pred(b) then return true end end
    return false
end

local kb1 = { { { text = "🔄 刷新清单", callback_data = "direct_list" } } }
tg.with_back(kb1)
assert(has(kb1, function(b) return b.callback_data == "refresh_status" end), "应补上返回看板")

local kb2 = { { { text = "⬅️ 返回代理", callback_data = "proxy_menu" } } }
local before = #kb2
tg.with_back(kb2)
assert(#kb2 == before, "已有返回时不应再补")

local kb3 = { { { text = "🔄 刷新看板", callback_data = "refresh_status" } } }
local before3 = #kb3
tg.with_back(kb3)
assert(#kb3 == before3, "看板自己不应多出返回")

assert(tg.with_back(nil) == nil, "nil 键盘应原样返回")
assert(#tg.with_back({}) == 1, "空键盘应补上返回")

print("PASS: 发送层自动补返回 —— 缺失则补、已有则跳过、看板不重复、nil 安全")
