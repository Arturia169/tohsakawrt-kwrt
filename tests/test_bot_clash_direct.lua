package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path
-- 🔗 直连清单：转发脚本输出、非法域名绝不落到脚本
local sent, cmds = {}, {}
local OUT = "fxxk.dedyn.io\nblog.example.com\n"
package.preload["tohsakawrt.core"] = function()
    return { init = function() end, log = function() end,
        exec = function(c) cmds[#cmds + 1] = c; return OUT end,
        exec_line = function() return "" end,
        get_uci = function(_, _, _, d) return d end,
        get_state = function(_, d) return d end, set_state = function() end,
        progress_bar = function() return "" end }
end
package.preload["tohsakawrt.tg"] = function()
    return { send_msg = function(t) sent[#sent + 1] = t; return { ok = true } end,
        edit_msg = function(_, t) sent[#sent + 1] = t; return { ok = true } end,
        answer_callback = function() end,
        answer_and_edit = function(_, _, _, t) sent[#sent + 1] = t; return { ok = true } end,
        send_chat_action = function() end }
end
package.preload["tohsakawrt.system"] = function() return {} end
package.preload["tohsakawrt.modem"] = function() return {} end
package.preload["tohsakawrt.clash"] = function() return {} end
package.preload["tohsakawrt.esim"] = function() return {} end
package.preload["nixio"] = function() return {} end

local m = require("tohsakawrt.bot_sys")

m.cmd_direct_list()
assert(#sent == 1 and sent[1]:find("blog.example.com", 1, true), "清单应包含现有域名")

OUT = "ADDED"
sent, cmds = {}, {}
m.direct_add("newblog.example.com")
assert(cmds[1] and cmds[1]:find("tohsakawrt-clash-direct add newblog.example.com", 1, true), "应调用脚本 add")
assert(sent[1]:find("已加入直连", 1, true), "应提示已加入")

sent, cmds = {}, {}
m.direct_add("bad;rm -rf /")
assert(#cmds == 0, "非法域名绝不能调用脚本（实际调用了 " .. #cmds .. " 次）")
assert(sent[1]:find("格式不正确", 1, true), "非法域名应被拒绝")

OUT = "DELETED"
sent, cmds = {}, {}
m.direct_del("newblog.example.com")
assert(cmds[1] and cmds[1]:find("tohsakawrt-clash-direct del", 1, true), "应调用脚本 del")

print("PASS: 直连清单转发、add/del 调用脚本、非法域名不落脚本")
