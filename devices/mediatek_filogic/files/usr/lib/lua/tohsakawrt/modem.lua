-- TohsakaWrt 5G Cellular Modem Module
local M = {}

local core = require("tohsakawrt.core")
local nixio = require("nixio")
local json = require("luci.jsonc")

local MODEM_AT = "/usr/share/modem/modem_at.sh"

function M.get_port()
    local port = core.get_uci("modem", "modem0", "at_port", "/dev/ttyUSB3")
    if nixio and nixio.fs and nixio.fs.stat(port) then
        return port
    end
    if nixio and nixio.fs and nixio.fs.stat("/dev/ttyUSB3") then
        return "/dev/ttyUSB3"
    elseif nixio and nixio.fs and nixio.fs.stat("/dev/ttyUSB2") then
        return "/dev/ttyUSB2"
    end
    return port
end

function M.at(cmd, timeout)
    timeout = timeout or 3
    local port = M.get_port()
    if not nixio.fs.stat(port) or not nixio.fs.stat(MODEM_AT) then
        return nil, "Modem AT port or script not found"
    end
    local run_cmd = string.format("sh %s %s '%s' 2>/dev/null", MODEM_AT, port, cmd)
    return core.exec(run_cmd)
end

local function flatten_info_array(arr)
    local t = {}
    if type(arr) == "table" then
        for _, item in ipairs(arr) do
            if type(item) == "table" then
                for k, v in pairs(item) do
                    if k ~= "full_name" and v ~= "-" and v ~= "" then
                        t[k] = v
                    end
                end
            end
        end
    end
    return t
end

function M.info()
    local port = M.get_port()
    local cmd = string.format("sh /usr/share/modem/modem_info.sh %s quectel qualcomm 1 2>/dev/null", port)
    local raw = core.exec(cmd)
    local obj = raw and json.parse(raw)

    if obj and (obj.base_info or obj.cell_info) then
        local base = obj.base_info or {}
        local sim = flatten_info_array(obj.sim_info)
        local net = flatten_info_array(obj.network_info)
        local cell_obj = obj.cell_info or {}
        local cell = {}
        for mode_name, mode_list in pairs(cell_obj) do
            cell = flatten_info_array(mode_list)
            cell.mode_name = mode_name
            break
        end

        local cgpaddr = M.at("AT+CGPADDR=1") or ""
        local sim_ip = cgpaddr:match('%+CGPADDR:%s*%d+,%s*"([^",]+)') or "未获取"

        local rsrp = cell.RSRP
        local rsrq = cell.RSRQ
        local sinr = cell.SINR

        local band = cell.Band or ""
        if band ~= "" and not band:lower():match("^n") and not band:lower():match("^b") then
            if (cell.mode_name and cell.mode_name:match("NR5G")) or (net["Network Type"] and net["Network Type"]:match("NR5G")) then
                band = "n" .. band
            else
                band = "B" .. band
            end
        end

        return {
            oper = sim.ISP or "中国联通",
            mode = net["Network Type"] or cell.mode_name or "5G SA",
            band = (band ~= "") and band or "n78",
            sim_ip = sim_ip,
            temp = base.temperature or "未知",
            rsrp = rsrp and (rsrp .. " dBm") or nil,
            rsrq = rsrq and (rsrq .. " dB") or nil,
            sinr = sinr and (sinr .. " dB") or nil,
            rsrp_num = tonumber(rsrp),
            sinr_num = tonumber(sinr),
            ambr_dl = net["AMBR DL"] and (net["AMBR DL"] .. " Mbps") or nil,
            ambr_ul = net["AMBR UL"] and (net["AMBR UL"] .. " Mbps") or nil,
            qci = net["CQI DL"] or "6",
            pci = cell["Physical Cell ID"],
            cell_id = cell["Cell ID"]
        }
    end

    -- 兜底旧逻辑
    local cgpaddr = M.at("AT+CGPADDR=1") or ""
    local qnwinfo = M.at("AT+QNWINFO") or ""

    local sim_ip = cgpaddr:match('%+CGPADDR:%s*%d+,%s*"([^",]+)')
    local mode, plmn, band = qnwinfo:match('%+QNWINFO:%s*"([^"]*)","([^"]*)","([^"]*)"')

    local oper = "未知运营商"
    if plmn then
        if plmn == "46001" or plmn == "46006" or plmn == "46009" then
            oper = "中国联通"
        elseif plmn == "46000" or plmn == "46002" or plmn == "46004" or plmn == "46007" or plmn == "46008" then
            oper = "中国移动"
        elseif plmn == "46003" or plmn == "46005" or plmn == "46011" or plmn == "46012" then
            oper = "中国电信"
        elseif plmn == "46015" then
            oper = "中国广电"
        else
            oper = plmn
        end
    end

    return {
        sim_ip = sim_ip or "未获取",
        oper = oper,
        band = band or "未知频段",
        mode = mode or "未知制式"
    }
end

local function extract_sms_code(text)
    if not text then return nil end
    local code = text:match("验证码[为是:：%s]*([0-9a-zA-Z]+)")
    if not code then code = text:match("驗證碼[為是:：%s]*([0-9a-zA-Z]+)") end
    if not code then
        local l = text:lower()
        code = l:match("verification%s+code%s+is%s+([0-9a-z]+)")
        if not code then code = l:match("code%s+%(?([0-9a-z]+)%)?") end
        if not code then code = l:match("code%s+is%s+([0-9a-z]+)") end
    end
    if code and #code >= 4 and #code <= 8 then
        return code:upper()
    end
    return nil
end

local function parse_sms_ts(ts)
    if not ts then return 0 end
    local m, d, y, h, min, s = ts:match("(%d+)/(%d+)/(%d+)%s+(%d+):(%d+):(%d+)")
    if not y then return 0 end
    return tonumber(string.format("20%02d%02d%02d%02d%02d%02d", y, m, d, h, min, s)) or 0
end

function M.sms_list(storage, limit)
    storage = storage or "ME"
    limit = limit or 5
    local port = M.get_port()

    local cmd = string.format("sms_tool -d %s -s %s -j recv 2>/dev/null", port, storage)
    local raw = core.exec(cmd)
    if not raw or raw == "" then return nil end
    local ok, data = pcall(json.parse, raw)
    if not ok or type(data) ~= "table" then return nil end
    local msgs = (data and data.msg) or {}

    local multipart = {}
    local assembled = {}

    for _, m in ipairs(msgs) do
        if m.reference and m.part and m.total and m.total > 1 then
            local key = string.format("%s_%s", m.sender or "", tostring(m.reference))
            if not multipart[key] then
                multipart[key] = {
                    sender = m.sender,
                    timestamp = m.timestamp,
                    parts = {},
                    total = m.total,
                    sort_time = parse_sms_ts(m.timestamp),
                    first_index = m.index
                }
            end
            multipart[key].parts[m.part] = m.content or ""
        else
            table.insert(assembled, {
                index = m.index,
                sender = m.sender or "未知发件人",
                timestamp = m.timestamp or "未知时间",
                content = m.content or "",
                code = extract_sms_code(m.content),
                sort_time = parse_sms_ts(m.timestamp)
            })
        end
    end

    for _, mp in pairs(multipart) do
        local full_text = ""
        for p = 1, mp.total do
            full_text = full_text .. (mp.parts[p] or "")
        end
        table.insert(assembled, {
            index = mp.first_index,
            sender = mp.sender or "未知发件人",
            timestamp = mp.timestamp or "未知时间",
            content = full_text,
            code = extract_sms_code(full_text),
            sort_time = mp.sort_time
        })
    end

    table.sort(assembled, function(a, b)
        if a.sort_time ~= b.sort_time then return a.sort_time > b.sort_time end
        return (a.index or 0) > (b.index or 0)
    end)

    if limit and limit > 0 and #assembled > limit then
        local sliced = {}
        for i = 1, limit do
            table.insert(sliced, assembled[i])
        end
        return sliced
    end

    return assembled
end

function M.sms_poll_new()
    local port = M.get_port()
    local st_raw = core.exec(string.format("sms_tool -d %s -s ME status 2>/dev/null", port))
    local cur_used = tonumber(st_raw and st_raw:match("used:%s*(%d+)")) or 0

    local last_used = tonumber(core.get_state("sms_last_used", "-1")) or -1
    local last_ts = tonumber(core.get_state("sms_last_ts", "0")) or 0

    if last_used == -1 then
        -- 首次启动记录当前最新短信，避免历史短信刷屏
        local list = M.sms_list("ME", 1)
        if not list then return {} end
        local latest_ts = (list and list[1] and list[1].sort_time) or 0
        core.set_state("sms_last_used", tostring(cur_used))
        core.set_state("sms_last_ts", tostring(latest_ts))
        return {}
    end

    if cur_used <= last_used then
        if cur_used < last_used then
            core.set_state("sms_last_used", tostring(cur_used))
        end
        return {}
    end

    local all_sms = M.sms_list("ME", 10)
    if not all_sms then return {} end
    local new_sms = {}
    local max_ts = last_ts

    for _, sms in ipairs(all_sms) do
        if sms.sort_time > last_ts then
            table.insert(new_sms, sms)
            if sms.sort_time > max_ts then
                max_ts = sms.sort_time
            end
        end
    end

    core.set_state("sms_last_used", tostring(cur_used))
    core.set_state("sms_last_ts", tostring(max_ts))

    return new_sms
end

local function normalize_iccid(reply, label)
    if not reply or reply:upper():match("ERROR") then return "" end
    local payload = reply:match("%+?" .. label .. ":%s*([^%r%n]+)") or ""
    return payload:gsub('["%s]', ""):upper():gsub("[^0-9A-F]", "")
end

local function nodata_gate()
    local reply = M.at("AT+QCCID")
    local iccid = normalize_iccid(reply, "QCCID")
    if iccid == "" then
        reply = M.at("AT+CCID")
        iccid = normalize_iccid(reply, "CCID")
    end

    local enabled = core.get_uci("tohsakawrt-tgbot", "main", "modem_data_heal", "1")
    local prefixes = core.get_uci("tohsakawrt-tgbot", "main", "nodata_cards", {})
    if type(prefixes) ~= "table" then prefixes = { prefixes } end
    local matched = nil
    if enabled ~= "0" and iccid ~= "" then
        for _, value in ipairs(prefixes) do
            local prefix = tostring(value):gsub('["%s]', ""):upper():gsub("[^0-9A-F]", "")
            if prefix ~= "" and iccid:sub(1, #prefix) == prefix then
                matched = prefix
                break
            end
        end
    end

    local state = "normal"
    if iccid == "" then state = "unknown" end
    if enabled == "0" then state = "silent:modem_data_heal=0"
    elseif matched then state = "silent:" .. matched end

    local state_key = "tohsakawrt-5g-data.nodata-mode"
    local previous = core.get_state(state_key, "")
    if state ~= previous then
        if state:match("^silent:") then
            local prefix = state:sub(8)
            if prefix == "modem_data_heal=0" then
                core.log("tohsakawrt-modem-heal", "5G data heal paused by modem_data_heal=0")
            else
                core.log("tohsakawrt-modem-heal", "接码卡已识别（ICCID 前缀 " .. prefix .. "）：暂停数据自愈")
            end
        elseif state == "unknown" then
            core.log("tohsakawrt-modem-heal", "ICCID 读取失败，按数据卡处理并继续数据自愈")
        elseif previous ~= "" then
            core.log("tohsakawrt-modem-heal", "已恢复数据自愈")
        end
        core.set_state(state_key, state)
    end

    if state:match("^silent:") then
        os.remove("/tmp/tohsakawrt/state/5g_data_fails")
        os.remove("/tmp/tohsakawrt/state/5g_data_lastheal")
        return true
    end
    return false
end

function M.keepalive_and_heal()
    if nodata_gate() then return "NO_DATA_SIM" end

    local dev = "usb0"
    local f = io.open("/sys/class/net/" .. dev .. "/operstate", "r")
    if not f then return "NO_INTERFACE" end
    f:close()

    local ip_out = core.exec_line("ip -4 addr show " .. dev .. " 2>/dev/null | awk '/inet / {print $2; exit}'")
    if ip_out == "" then
        core.log("tohsakawrt-modem-heal", "5G usb0 lost IP, triggering ifup 5Ga")
        os.execute("ifup 5Ga 2>/dev/null")
        return "HEAL_NO_IP"
    end

    -- Independent ping via usb0 (protecting hot-standby channel from operator PDP sleep)
    local ret = os.execute("ping -c 1 -W 2 -I " .. dev .. " 223.5.5.5 >/dev/null 2>&1")
    if ret == 0 then
        core.set_state("5g_data_fails", "0")
        return "HEALTHY"
    end

    local fails = tonumber(core.get_state("5g_data_fails", "0")) or 0
    fails = fails + 1
    core.set_state("5g_data_fails", tostring(fails))

    local now = os.time()
    local last_heal = tonumber(core.get_state("5g_data_lastheal", "0")) or 0
    if (now - last_heal) < 60 then
        return "THROTTLED"
    end
    core.set_state("5g_data_lastheal", tostring(now))

    if fails == 1 then
        core.log("tohsakawrt-modem-heal", "5G ping timeout (Stage 1): ifup 5Ga")
        os.execute("ifup 5Ga 2>/dev/null")
        return "HEAL_STAGE_1"
    elseif fails == 2 then
        core.log("tohsakawrt-modem-heal", "5G ping timeout (Stage 2): AT+QNETDEVCTL=1,1,1")
        M.at("AT+QNETDEVCTL=1,1,1")
        os.execute("sleep 2; ifup 5Ga 2>/dev/null")
        return "HEAL_STAGE_2"
    else
        core.log("tohsakawrt-modem-heal", "5G ping timeout (Stage 3): AT+CFUN=0/1 reset")
        M.at("AT+CFUN=0")
        os.execute("sleep 2")
        M.at("AT+CFUN=1")
        os.execute("sleep 3; ifup 5Ga 2>/dev/null")
        
        local tg = require("tohsakawrt.tg")
        tg.send_msg("🔴 <b>5G 热备链路脱网告警</b>\n━━━━━━━━━━━━━━━━━━\n📊 <b>探测结果</b>：连续 3 次数据探测超时\n🔄 <b>已执行动作</b>：射频重注网自愈\n━━━━━━━━━━━━━━━━━━\n<i>请留意模组连接状态。</i>\n\n🕰️ <i>" .. os.date("%Y-%m-%d %H:%M:%S") .. "</i>")
        return "HEAL_STAGE_3"
    end
end

return M
