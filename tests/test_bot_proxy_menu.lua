package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path
-- 🌐 代理面板：状态渲染 + 按钮齐全 + 不吞异常
local sent, kb_dump = {}, {}
package.preload["tohsakawrt.core"] = function()
    return { init=function() end, log=function() end, exec=function() return "" end,
        exec_line=function(c) if tostring(c):find("clash%-direct status") then return "DIRECT_RULES:3" end return "" end,
        get_uci=function(_,_,_,d) return d end, get_state=function(_,d) return d end,
        set_state=function() end, progress_bar=function() return "" end }
end
package.preload["tohsakawrt.clash"] = function()
    return { status = function() return { running = true, version = "alpha-test" } end }
end
package.preload["tohsakawrt.tg"] = function()
    return { send_msg=function(t, kb) sent[#sent+1]=t; kb_dump=kb; return {ok=true} end,
        edit_msg=function(_,t,kb) sent[#sent+1]=t; kb_dump=kb; return {ok=true} end,
        answer_callback=function() end,
        answer_and_edit=function(_,_,_,t,kb) sent[#sent+1]=t; kb_dump=kb; return {ok=true} end,
        send_chat_action=function() end }
end
package.preload["tohsakawrt.system"]=function() return {} end
package.preload["tohsakawrt.modem"]=function() return {} end
package.preload["tohsakawrt.esim"]=function() return {} end
package.preload["nixio"]=function() return {} end
local m = require("tohsakawrt.bot_net")
m.cmd_proxy_menu()
assert(#sent == 1, "应发送一条面板消息")
assert(sent[1]:find("运行中", 1, true), "应显示运行状态")
assert(sent[1]:find("alpha%-test") or sent[1]:find("alpha-test", 1, true), "应显示内核版本")
assert(sent[1]:find("3", 1, true) and sent[1]:find("强制直连", 1, true), "应显示直连规则条数")
local names = {}
for _, row in ipairs(kb_dump or {}) do for _, b in ipairs(row) do names[#names+1] = b.text end end
local joined = table.concat(names, "|")
assert(joined:find("直连清单", 1, true) and joined:find("节点分流", 1, true), "按钮应含直连清单与节点分流")
assert(joined:find("返回看板", 1, true), "按钮应含返回看板")
assert(sent[1]:find("/smart", 1, true), "面板里应说明 /smart 用法")
print("PASS: 代理面板状态渲染、按钮齐全、含 /smart 用法说明")
