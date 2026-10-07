package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path
local sent, cmds = {}, {}
local OUT = "DIRECT_MS:80\nPROXY_MS:400\nVERDICT:DIRECT\n"
package.preload["tohsakawrt.core"] = function()
    return { init=function() end, log=function() end,
        exec=function(c) cmds[#cmds+1]=c; return OUT end, exec_line=function() return "" end,
        get_uci=function(_,_,_,d) return d end, get_state=function(_,d) return d end,
        set_state=function() end, progress_bar=function() return "" end }
end
package.preload["tohsakawrt.tg"] = function()
    return { send_msg=function(t) sent[#sent+1]=t; return {ok=true} end,
        edit_msg=function(_,t) sent[#sent+1]=t; return {ok=true} end, answer_callback=function() end,
        answer_and_edit=function(_,_,_,t) sent[#sent+1]=t; return {ok=true} end, send_chat_action=function() end }
end
package.preload["tohsakawrt.system"]=function() return {} end
package.preload["tohsakawrt.modem"]=function() return {} end
package.preload["tohsakawrt.clash"]=function() return {} end
package.preload["tohsakawrt.esim"]=function() return {} end
package.preload["nixio"]=function() return {} end
local m = require("tohsakawrt.bot_sys")
m.direct_smart("blog.example.com")
assert(cmds[1] and cmds[1]:find("smart blog.example.com",1,true), "应调用 smart")
assert(sent[1]:find("走直连更快",1,true), "应给出直连更快的结论")
assert(sent[1]:find("80",1,true) and sent[1]:find("400",1,true), "应显示两个数字")
OUT = "DIRECT_MS:500\nPROXY_MS:100\nVERDICT:PROXY\n"
sent, cmds = {}, {}
m.direct_smart("blog.example.com")
assert(sent[1]:find("走代理更快",1,true), "应给出代理更快的结论")
sent, cmds = {}, {}
m.direct_smart("bad;rm -rf /")
assert(#cmds == 0 and sent[1]:find("格式不正确",1,true), "非法域名不应调用脚本")
print("PASS: /smart 转发、结论正确、非法域名不落脚本")
