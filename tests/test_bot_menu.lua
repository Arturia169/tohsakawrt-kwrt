-- 回归用例：主菜单收口（6 个入口）后，/help 必须发菜单卡而不是 32 行清单；
-- 分区按钮必须走真实回调分发；破坏性按钮必须先弹确认框，不能直接执行。
package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;" .. package.path

local sent, execs

local function reset()
    sent, execs = {}, {}
    for _, n in ipairs({
        "tohsakawrt.bot", "tohsakawrt.bot_common", "tohsakawrt.bot_net", "tohsakawrt.bot_sys",
        "tohsakawrt.bot_direct", "tohsakawrt.bot_modem", "tohsakawrt.bot_esim",
        "tohsakawrt.core", "tohsakawrt.tg", "tohsakawrt.system", "tohsakawrt.modem",
        "tohsakawrt.clash", "tohsakawrt.esim", "nixio",
    }) do
        package.loaded[n] = nil
    end
end

local function run_with(upd)
    reset()
    local n = 0
    package.preload["tohsakawrt.core"] = function()
        return {
            init = function() end,
            log = function() end,
            exec = function(cmd) execs[#execs + 1] = tostring(cmd); return "" end,
            exec_line = function() return "" end,
            get_uci = function(_, _, opt, def)
                if opt == "enabled" then return "1" end
                if opt == "token" then return "dummy" end
                if opt == "chat_id" or opt == "user_id" then return "77" end
                return def
            end,
            get_state = function(_, d) return d end,
            set_state = function() end,
            progress_bar = function() return "" end,
        }
    end
    package.preload["tohsakawrt.tg"] = function()
        return {
            get_updates = function()
                n = n + 1
                if n == 1 then return { result = {} } end
                if n == 2 then return { result = { upd } } end
                error("__STOP__")
            end,
            send_msg = function(t, kb) sent[#sent + 1] = { text = tostring(t), kb = kb }; return { ok = true } end,
            edit_msg = function(_, t, kb) sent[#sent + 1] = { text = tostring(t), kb = kb, edit = true }; return { ok = true } end,
            answer_callback = function() end,
            answer_and_edit = function(_, _, _, t) sent[#sent + 1] = { text = tostring(t) }; return { ok = true } end,
            send_chat_action = function() end,
        }
    end
    package.preload["tohsakawrt.system"] = function() return {} end
    package.preload["tohsakawrt.modem"] = function() return {} end
    package.preload["tohsakawrt.clash"] = function()
        return { status = function() return { running = true, version = "test" } end }
    end
    package.preload["tohsakawrt.esim"] = function() return {} end
    package.preload["nixio"] = function() return {} end

    local ok, err = pcall(require("tohsakawrt.bot").run)
    assert(not ok and tostring(err):find("__STOP__", 1, true),
        "run 应终止在哨兵处，实际: " .. tostring(err))
end

local function msg_upd(text)
    return { update_id = 1, message = {
        chat = { id = "77", type = "private" }, from = { id = "77" }, text = text } }
end

local function cb_upd(data)
    return { update_id = 2, callback_query = {
        id = "cb1", data = data,
        message = { message_id = 9, chat = { id = "77", type = "private" } },
        from = { id = "77" } } }
end

local function find_sent(sub)
    for _, s in ipairs(sent) do
        if s.text:find(sub, 1, true) then return s end
    end
    return nil
end

local function kb_has(kb, data)
    if type(kb) ~= "table" then return false end
    for _, row in ipairs(kb) do
        for _, btn in ipairs(row) do
            if btn.callback_data == data then return true end
        end
    end
    return false
end

-- 1) /help 发主菜单卡
run_with(msg_upd("/help"))
local menu = find_sent("TohsakaWrt 控制台")
assert(menu, "/help 必须发出主菜单卡")
assert(type(menu.kb) == "table" and #menu.kb == 4, "主菜单应有 4 行按钮，实际 " .. tostring(menu.kb and #menu.kb))
for _, d in ipairs({ "menu_net", "menu_sim", "menu_log", "menu_sys", "menu_all", "proxy_menu" }) do
    assert(kb_has(menu.kb, d), "主菜单缺少入口按钮: " .. d)
end

-- 2) 分区按钮走真实回调分发（编辑原消息，不新发）
run_with(cb_upd("menu_net"))
local netcard = find_sent("网络")
assert(netcard and netcard.edit, "menu_net 应编辑当前消息为网络分区")
assert(kb_has(netcard.kb, "menu_home"), "网络分区必须有返回按钮")

-- 3) 返回键回到主菜单
run_with(cb_upd("menu_home"))
assert(find_sent("TohsakaWrt 控制台"), "返回键应回到主菜单")

-- 4) 破坏性按钮必须先确认，绝不能直接重启
run_with(cb_upd("req_reboot"))
local confirm = find_sent("敏感操作确认")
assert(confirm, "重启按钮必须先弹确认框")
for _, c in ipairs(execs) do
    assert(not tostring(c):find("reboot", 1, true), "确认前不得执行 reboot，实际: " .. tostring(c))
end

print("PASS: 主菜单收口生效（6 入口 + 返回 + 破坏性操作先确认）")
