-- Local eSIM profile helpers and background modem jobs.
local M = {}

local core = require("tohsakawrt.core")
local modem = require("tohsakawrt.modem")
local json = require("luci.jsonc")

local STATE = "/tmp/tohsakawrt/state"

-- Keep quoting local: offline tests stub tohsakawrt.core, so a shared core helper would test the stub instead of this code.
local function shell_quote(value)
    return "'" .. tostring(value):gsub("[\n\r\t]", " "):gsub("'", "'\\''") .. "'"
end

local function lpa_payload(output)
    local last
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        if line:match('^%s*{"type":"lpa"') then last = line end
    end
    if not last then return nil, "no_json", "" end
    local ok, obj = pcall(json.parse, last)
    if not ok or type(obj) ~= "table" or type(obj.payload) ~= "table" then return nil, "parse", "" end
    if tonumber(obj.payload.code) ~= 0 then return nil, "lpa_error", tostring(obj.payload.message or "") end
    return obj.payload.data or obj.payload
end

local function safe_text(s)
    return tostring(s or ""):gsub("[\r\n]", " "):gsub("%d+", function(value)
        if (#value >= 18 and #value <= 22) or #value == 32 then return value:sub(1, 6) .. "…" .. value:sub(-4) end
        return value
    end):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

function M.mask(value)
    value = tostring(value or "")
    if #value < 10 then return "未知" end
    return value:sub(1, 6) .. "…" .. value:sub(-4)
end

function M.parse_lpa(output)
    return lpa_payload(output)
end

function M.resolve(profiles, selector)
    selector = tostring(selector or ""):match("^%s*(.-)%s*$") or ""
    if selector:match("^%d+$") and #selector >= 18 and #selector <= 22 then return nil, "full_iccid" end
    local n = tonumber(selector)
    if n and n == math.floor(n) and n >= 1 then
        local p = profiles[n]
        if p then return p end
        return nil, "not_found"
    end
    local key = selector:lower()
    for _, p in ipairs(profiles or {}) do
        local mask = M.mask(p.iccid)
        local nickname = tostring(p.profileNickname or ""):lower()
        local provider = tostring(p.serviceProviderName or ""):lower()
        if key ~= "" and (nickname:find(key, 1, true) or provider:find(key, 1, true) or mask:lower():find(key, 1, true)) then return p end
    end
    return nil, "not_found"
end

local function lpac(command)
    local p = io.popen(command .. " 2>/dev/null", "r")
    if not p then return nil end
    local out = p:read("*a") or ""
    p:close()
    return out
end

function M.list()
    local profiles, err, detail = lpa_payload(lpac("lpac profile list"))
    if type(profiles) ~= "table" then return nil, err or "bad_profiles", detail end
    return profiles
end

function M.list_hint(err, detail)
    if err == "lpa_error" then
        local message = tostring(detail or ""):lower()
        if message:find("euicc_init", 1, true) then
            return "当前卡不是 eSTK（未检测到 eUICC），换回 eSTK 才能管理卡内号码"
        end
        if message:find("no_card", 1, true) or message:find("no_sim", 1, true) then
            return "读不到 SIM 卡，请确认卡已插好"
        end
    end
    return "请稍后重试"
end

local function chip_eid()
    local data = lpa_payload(lpac("lpac chip info"))
    if type(data) ~= "table" then return nil end
    return data.eidValue or data.eid or (data.chip and (data.chip.eidValue or data.chip.eid))
end

function M.card_text(profiles)
    local lines = {
        "📇 <b>eSIM 卡内配置清单</b>",
        "━━━━━━━━━━━━━━━━━━"
    }
    local buttons = {}
    local max_profiles = math.min(#profiles, #profiles > 5 and 4 or 5)
    for i = 1, #profiles do
        buttons[#buttons + 1] = { text = "🔀 启用 #" .. i, callback_data = "enable:" .. i }
    end
    for i = 1, max_profiles do
        local p = profiles[i]
        local is_act = (p.profileState == "enabled")
        local icon = is_act and "🟢" or "⚪"
        local status_tag = is_act and " <b>[当前生效]</b>" or ""
        local name = p.profileNickname
        if not name or name == "" then name = p.serviceProviderName end
        if not name or name == "" then name = p.profileName end
        name = safe_text(name or "未命名")
        local provider = p.serviceProviderName and safe_text(p.serviceProviderName) or ""
        local prov_str = (provider ~= "" and provider ~= name) and (" (" .. provider .. ")") or ""

        local phone = core.get_uci("tohsakawrt-tgbot", "numbers", "n_" .. tostring(p.iccid), "")
        local phone_line = (phone ~= "") and string.format("    ├ 电话: <code>%s</code>\n", phone) or ""

        lines[#lines + 1] = string.format("%s <b>#%d %s%s</b>%s", icon, i, name, prov_str, status_tag)
        if phone ~= "" then
            lines[#lines + 1] = string.format("    ├ 电话: <code>%s</code>", phone)
        end
        lines[#lines + 1] = string.format("    └ 卡号: <code>%s</code>", M.mask(p.iccid))
        if i < max_profiles then
            lines[#lines + 1] = ""
        end
    end
    if #profiles > max_profiles then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "…另有 " .. (#profiles - max_profiles) .. " 个号码"
    end
    table.insert(lines, "━━━━━━━━━━━━━━━━━━")
    local eid = chip_eid()
    if eid then
        table.insert(lines, string.format("💳 <b>卡片 EID</b>：<code>%s</code>", M.mask(eid)))
    end
    return table.concat(lines, "\n"), { buttons, { { text = "🔄 刷新", callback_data = "refresh_cards" } } }
end

local function read_reply(command)
    local reply = modem.at(command, 5) or ""
    return tostring(reply)
end

local function registration(reply)
    local stat = tonumber(reply:match("%+CEREG:%s*%d+,%s*(%d+)") or reply:match("%+CEREG:%s*(%d+)"))
    local labels = { [0] = "未注册（不搜索）", [1] = "已注册（本地）", [2] = "未注册（搜索中）", [3] = "注册被拒", [5] = "已注册（漫游）" }
    return stat, labels[stat] or "未知"
end

local function iccid_parts(reply)
    local v = reply:match("%+?QCCID:%s*\"?([%d]+)") or ""
    if #v < 10 then return "", "" end
    return v:sub(1, 6), v:sub(-4)
end

local function sleep(seconds) os.execute("sleep " .. tostring(seconds)) end

function M.reload_flow()
    local start = os.time()
    local old_p, old4 = iccid_parts(read_reply("AT+QCCID"))
    modem.at("AT+CFUN=1,1", 5)
    sleep(45)
    local ready, cpin = false, "未知"
    local consecutive = 0
    for _ = 1, 12 do
        cpin = read_reply("AT+CPIN?"):match("%+CPIN:%s*([^\r\n]+)") or "未知"
        cpin = cpin:match("^%s*(.-)%s*$")
        if cpin:find("READY", 1, true) then consecutive = consecutive + 1 else consecutive = 0 end
        if consecutive >= 2 then ready = true; break end
        sleep(10)
    end
    local new_p, new4 = iccid_parts(read_reply("AT+QCCID"))
    local qnw = read_reply("AT+QNWINFO"):match("%+QNWINFO:%s*([^\r\n]+)") or "未知"
    local cereg_reply = read_reply("AT+CEREG?")
    local stat, label = registration(cereg_reply)
    local recovered = false
    if stat ~= 1 and stat ~= 5 then
        recovered = true
        modem.at("AT+CFUN=0", 5); sleep(5); modem.at("AT+CFUN=1", 5)
        for _ = 1, 6 do
            sleep(10)
            stat, label = registration(read_reply("AT+CEREG?"))
            if stat == 1 or stat == 5 then break end
        end
        new_p, new4 = iccid_parts(read_reply("AT+QCCID"))
        qnw = read_reply("AT+QNWINFO"):match("%+QNWINFO:%s*([^\r\n]+)") or "未知"
        stat, label = registration(read_reply("AT+CEREG?"))
    end
    local changed = old_p ~= "" and new_p ~= "" and (old_p ~= new_p or old4 ~= new4)
    return { ready = ready, cpin = cpin, old_p = old_p, old4 = old4, prefix = new_p, last4 = new4,
        changed = changed, qnw = qnw, label = label, recovered = recovered,
        elapsed = math.max(0, os.time() - start) }
end

local function reload_card(r)
    local lines = { "🔄 <b>模组重载</b>", "━━━━━━━━━━━━━━━━━━",
        "📶 <b>SIM</b>：" .. (r.ready and "就绪" or "未就绪") .. "（<code>" .. safe_text(r.cpin) .. "</code>）" }
    if r.prefix ~= "" then lines[#lines + 1] = "💳 <b>卡（ICCID）</b>：<code>" .. r.prefix .. "…" .. r.last4 .. "</code>"
    else lines[#lines + 1] = "💳 <b>卡（ICCID）</b>：读取失败" end
    if r.changed then lines[#lines + 1] = "🔁 <b>识别到换卡</b>：<code>" .. r.old_p .. "…" .. r.old4 .. " → " .. r.prefix .. "…" .. r.last4 .. "</code>" end
    local network, operator, band = tostring(r.qnw or "未知"):match('^%s*"([^"]*)"%s*,%s*"?(%d+)"?%s*,%s*"([^"]*)"%s*,?%s*%d*%s*$')
    if network and operator and band then
        local operators = {
            ["46000"] = "中国移动", ["46002"] = "中国移动", ["46007"] = "中国移动", ["46008"] = "中国移动",
            ["46001"] = "中国联通", ["46006"] = "中国联通", ["46009"] = "中国联通",
            ["46003"] = "中国电信", ["46005"] = "中国电信", ["46011"] = "中国电信"
        }
        lines[#lines + 1] = "📶 <b>网络制式</b>：<code>" .. safe_text(network) .. "</code>"
        lines[#lines + 1] = "📡 <b>运营商</b>：<code>" .. safe_text(operators[operator] or operator) .. "</code>"
        lines[#lines + 1] = "📻 <b>频段</b>：<code>" .. safe_text(band) .. "</code>"
    else
        lines[#lines + 1] = "📶 <b>网络</b>：<code>" .. safe_text(r.qnw) .. "</code>"
    end
    lines[#lines + 1] = "📡 <b>网络注册</b>：" .. safe_text(r.label)
    lines[#lines + 1] = "⏱️ <b>耗时</b>：约 <code>" .. safe_text(r.elapsed) .. "</code> 秒"
    if r.recovered then lines[#lines + 1] = "ℹ️ 已自动补做一次射频重注网" end
    return table.concat(lines, "\n")
end

local function result_card(output)
    return output .. "\n\n🕰️ <i>" .. os.date("%Y-%m-%d %H:%M:%S") .. "</i>"
end

local function append_main_uplink_warning(output, main_uplink)
    if main_uplink == "1" then
        return output .. "\n⚠️ 模组当前是主出口，期间会断网约 2 分钟"
    end
    return output
end

local function push_result(output, message_id, kind)
    local ok, tg = pcall(require, "tohsakawrt.tg")
    if not ok or type(tg) ~= "table" then return end
    local send_ok = pcall(tg.send_msg, result_card(output))
    if message_id ~= "" and message_id ~= "0" then
        local title = kind == "reload" and "模组重载" or (kind == "switch" and "号码切换" or "写卡")
        pcall(tg.edit_msg, message_id, "✅ <b>" .. title .. "</b> 已完成 · 结果见下方 👇")
    end
    return send_ok
end

local function write(path, value)
    local f = io.open(path, "w")
    if f then f:write(value); f:close(); return true end
    return false
end

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

function M.job_result(id)
    return read(STATE .. "/esim-job-" .. tostring(id) .. ".txt")
end

function M.start_job(kind, id, target_iccid, display_name, main_uplink, extra_arg, message_id)
    core.init()
    local spec = STATE .. "/esim-job-" .. id .. ".spec"
    local result = STATE .. "/esim-job-" .. id .. ".txt"
    local target = target_iccid or ""
    if kind == "switch" and target ~= "" and (not target:match("^%d+$") or #target < 18 or #target > 22) then return false end
    local content = kind .. "\n" .. target .. "\n" .. safe_text(display_name or "号码") .. "\n" .. (main_uplink and "1" or "0") .. "\n" .. (extra_arg or "") .. "\n" .. tostring(message_id or "")
    if not write(spec, content) then return false end
    os.remove(result)
    local code = "package.path='/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;'..package.path; require('tohsakawrt.esim').worker('" .. id .. "')"
    local command = 'lua -e "' .. code .. '" >/dev/null 2>&1 &'
    return os.execute(command) == 0
end

function M.worker(id)
    core.init()
    local spec = read(STATE .. "/esim-job-" .. id .. ".spec") or ""
    local lines = {}
    for l in (spec .. "\n"):gmatch("([^\r\n]*)\r?\n") do table.insert(lines, l) end
    local kind = lines[1] or ""
    local target = lines[2] or ""
    local display_name = lines[3] or ""
    local main_uplink = lines[4] or "0"
    local extra_arg = lines[5] or ""
    local message_id = lines[6] or ""
    local output

    if kind == "download" then
        local ac = target
        local confirm = extra_arg
        local cmd = "lpac profile download -a " .. shell_quote(ac)
        if confirm ~= "" then
            cmd = cmd .. " -c " .. shell_quote(confirm)
        end
        local raw = lpac(cmd)
        local payload, err = lpa_payload(raw)
        if not payload then
            output = "⚠️ <b>下载写卡失败</b>\n━━━━━━━━━━━━━━━━━━\n<b>原因</b>：<code>" .. safe_text(err or "激活码无效或无法连接 SM-DP+ 服务器") .. "</code>"
        else
            output = "🎉 <b>eSIM 写卡</b>\n━━━━━━━━━━━━━━━━━━\n✅ <b>结果</b>：Profile 已成功写入 eSTK 芯片\n💡 <i>点击「刷新」或发送 /cards 即可查看并启用新号码。</i>"
        end
    elseif kind == "switch" and target and target:match("^%d+$") and #target >= 18 and #target <= 22 then
        local raw = lpac("lpac profile enable " .. target)
        local payload = lpa_payload(raw)
        if not payload then output = "⚠️ <b>号码切换</b>\n━━━━━━━━━━━━━━━━━━\n<b>切换结果</b>：启用失败，请刷新列表后重试。"
        else
            local r = M.reload_flow()
            local _, expected = target:sub(1, 6), target:sub(-4)
            local verified = r.prefix == target:sub(1, 6) and r.last4 == expected
            output = "🔀 <b>号码切换</b>\n━━━━━━━━━━━━━━━━━━\n"
                .. (verified and ("✅ <b>切换结果</b>：已切到 <code>" .. safe_text(display_name or "号码") .. "（" .. target:sub(1, 6) .. "…" .. target:sub(-4) .. "）</code>")
                or ("⚠️ <b>切换结果</b>：复核未通过，模组实际读到 <code>" .. (r.prefix ~= "" and (r.prefix .. "…" .. r.last4) or "未知") .. "</code>"))
                .. "\n📡 <b>网络注册</b>：" .. safe_text(r.label) .. "\n⏱️ <b>耗时</b>：约 <code>" .. safe_text(r.elapsed) .. "</code> 秒"
            output = append_main_uplink_warning(output, main_uplink)
        end
    else
        output = reload_card(M.reload_flow())
        output = append_main_uplink_warning(output, main_uplink)
    end
    write(STATE .. "/esim-job-" .. id .. ".txt", output)
    pcall(push_result, output, message_id, kind)
end

function M.reload_text(r) return reload_card(r) end
return M
