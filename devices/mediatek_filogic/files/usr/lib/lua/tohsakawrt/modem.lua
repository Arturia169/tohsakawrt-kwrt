-- TohsakaWrt 5G Cellular Modem Module
local M = {}

local core = require("tohsakawrt.core")
local nixio = require("nixio")
local json = require("luci.jsonc")

local MODEM_AT = "/usr/share/modem/modem_at.sh"

-- AT 口全局互斥锁包装器。
-- 背景：AT 口原先有三个互不互斥的写者 —— modem_at.sh（有 flock）、
-- sms_tool（直接用串口，无锁）、lpac（无锁）。modem_at.sh 的注释自称"全局 AT 互斥"，
-- 实际只覆盖三分之一；并发下 sms_tool 会挂住，而它是从机器人主循环每 12 秒无条件调用的。
local AT_LOCK = "/usr/bin/tohsakawrt-at-lock"
local AT_LOCK_OK = (function()
    local f = io.open(AT_LOCK, "r")
    if f then f:close() return true end
    return false
end)()

-- 把一条需要独占 AT 口的命令包装成"持锁执行"。
-- wait 可选：抢锁最长等待秒数（默认 8）。高频轮询传小值，锁忙时宁可本轮跳过也不空等。
local function at_locked(cmd, wait)
    if AT_LOCK_OK then
        if wait then
            return string.format("TWR_AT_LOCK_WAIT=%d %s %s", wait, AT_LOCK, cmd)
        end
        return string.format("%s %s", AT_LOCK, cmd)
    end
    return cmd
end

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
    timeout = math.max(1, math.floor(tonumber(timeout) or 3))
    local port = M.get_port()
    if not nixio.fs.stat(port) or not nixio.fs.stat(MODEM_AT) then
        return nil, "Modem AT port or script not found"
    end
    -- cmd 会被拼进 shell 命令，必须转义。原先直接套一对单引号，输入里带 ' 就会截断引号，
    -- 命令被拆成两段后静默失败（2>/dev/null 把错误也吞了）。
    -- 唯一的外部入口是 cli.lua 的 `tohsakawrt modem at <用户输入>`。
    local inner = string.format("sh %s %s %s 2>/dev/null", MODEM_AT, port, core.shell_quote(cmd))
    local run_cmd = string.format(
        "if command -v timeout >/dev/null 2>&1; then timeout %d %s; else %s & __p=$!; ( sleep %d; kill -9 $__p 2>/dev/null ) >/dev/null 2>&1 & __w=$!; wait $__p; kill $__w 2>/dev/null; fi",
        timeout, inner, inner, timeout)
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

-- 解析 AT+QENG="servingcell"，取出小区标识（Cell ID / PCID）。
--
-- 为什么需要它：厂商脚本在 NR5G-SA 下不给这两项（实测 cell 表里 RSRP/SINR/Band 都有，
-- 唯独 Cell ID 与 Physical Cell ID 为空），于是信号趋势里"最近小区"永远是 "-"。
-- 而这两个值决定了完全不同的处理方式：
--   * 同一个小区、信号变差 → 覆盖/干扰问题，可考虑锁频段或锁小区
--   * 换了另一个小区     → 是驻留策略/重选问题，锁频段没用
-- 不看小区 ID 就无法区分这两种情况。
--
-- ⚠️ 两种布局必须分开处理，字段位置不同，混用会取到完全无关的数字：
--   SA / LTE: "servingcell","NOCONN","NR5G-SA","TDD",460,01,<CellID>,<PCID>,...
--             → 切分后 f[6]=CellID（十六进制字符串） f[7]=PCID
--   NSA:      "servingcell","NOCONN","NR5G-NSA",460,01,<PCID>,...
--             → NSA 响应里【没有 CellID】，f[5]=PCID
-- 取不到就返回 nil，绝不编造占位值（前车之鉴：旧代码编造 n78/"6" 污染过趋势）。
local function parse_qeng_cell(resp)
    if not resp or resp == "" then return nil end
    local body = resp:match('+QENG:%s*"servingcell",(.*)')
    if not body then return nil end

    local f = {}
    for part in (body .. ","):gmatch("([^,]*),") do
        part = part:gsub('^%s*"', ""):gsub('"%s*$', ""):gsub("^%s+", ""):gsub("%s+$", "")
        f[#f + 1] = part
    end

    local rat = f[2] or ""
    local cid, pci
    if rat:match("NSA") then
        pci = f[5]
    else
        cid, pci = f[6], f[7]
    end

    local function clean(v)
        if v == nil or v == "" or v == "-" then return nil end
        return v
    end
    local c, p = clean(cid), clean(pci)
    if not c and not p then return nil end
    return { cell_id = c, pci = p }
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

        -- 厂商脚本在某些制式下不给 cell.Band：实测切到 LTE 时 cell 里 RSRP/SINR 都有、
        -- 唯独 Band 为空，于是趋势样本把频段记成 "-"，凌晨 5G 基站关闭那 1.5 小时
        -- 就完全看不出自己落在哪个 LTE 频段上（而这正是用户最需要看到的一段）。
        -- 这里只在 cell.Band 为空时才补一次 AT+QNWINFO —— 该响应里本来就带
        -- "LTE BAND 3" / "NR5G BAND 78"，所以【正常路径零额外开销】。
        if band == "" then
            local qnw = M.at("AT+QNWINFO") or ""
            local qband = qnw:match('%+QNWINFO:%s*"[^"]*","[^"]*","([^"]*)"')
            if qband and qband ~= "" then
                -- 必须取 "BAND"【之后】的数字。不能用 qband:match("(%d+)")：那会取到
                -- "NR5G BAND 78" 里的 "5"（来自 NR5G 自身），把频段记成 n5 ——
                -- 一个看起来合理、却完全错误的频段，会静默污染趋势。
                -- 注意 "LTE BAND 3" 没有前置数字，所以只有 NR 这条路径会踩坑，更难发现。
                local num = qband:match("[Bb][Aa][Nn][Dd]%s*(%d+)")
                if num then
                    -- "NR5G BAND 78" → n78 ; "LTE BAND 3" → B3 ; "WCDMA BAND 1" → B1
                    if qband:upper():match("NR") then
                        band = "n" .. num
                    else
                        band = "B" .. num
                    end
                end
            end
        end

        -- 小区标识兜底：厂商脚本在 NR5G-SA 下不给 Cell ID / PCID（RSRP/SINR/Band 都有，
        -- 唯独这两项为空）。与上面 Band 的兜底同一思路 —— 只在缺失时才补一次
        -- AT+QENG="servingcell"，读得到就零额外开销。
        local pci = cell["Physical Cell ID"]
        local cid = cell["Cell ID"]
        local function missing(v) return v == nil or v == "" or v == "-" end
        if missing(cid) or missing(pci) then
            local q = parse_qeng_cell(M.at('AT+QENG="servingcell"') or "")
            if q then
                if missing(cid) and q.cell_id then cid = q.cell_id end
                if missing(pci) and q.pci then pci = q.pci end
            end
        end

        -- 频段读不到就保持 nil：旧代码在此补 "n78"，而 tohsakawrt-signal-log 会把
        -- m.band 当作真实驻留频段记入趋势样本，频段设置页的"当前驻留频段"也照此显示，
        -- 于是编造的 n78 会污染趋势图，且用户无法区分真实读数与默认值。
        if band == "" then band = nil end

        -- oper/mode/band 读不到就是 nil，由展示层显示"未获取"。
        -- 旧代码分别补 "中国联通" / "5G SA" / "n78"：这些是编造的具体事实（而非"未知"占位），
        -- 会把默认值伪装成真实网络状态。
        return {
            oper = sim.ISP,
            mode = net["Network Type"] or cell.mode_name,
            band = band,
            sim_ip = sim_ip,
            temp = base.temperature or "未知",
            rsrp = rsrp and (rsrp .. " dBm") or nil,
            rsrq = rsrq and (rsrq .. " dB") or nil,
            sinr = sinr and (sinr .. " dB") or nil,
            rsrp_num = tonumber(rsrp),
            sinr_num = tonumber(sinr),
            ambr_dl = net["AMBR DL"] and (net["AMBR DL"] .. " Mbps") or nil,
            ambr_ul = net["AMBR UL"] and (net["AMBR UL"] .. " Mbps") or nil,
            -- CQI（信道质量指示，0–15）与 5QI（5G QoS 标识，1–9）是两个完全不同的量。
            -- 旧代码把它命名为 qci 并补默认值 "6"，展示层再标成"5QI 标准移动宽带"，
            -- 等于用信道质量冒充业务 QoS 等级。读不到就是 nil，不再补 "6"。
            cqi = net["CQI DL"],
            pci = pci,
            cell_id = cid
        }
    end

    -- 兜底旧逻辑
    -- 本分支的 "未知运营商" / "未知频段" / "未知制式" 是"未知"占位而非编造事实，予以保留；
    -- oper 由 PLMN 映射得出（46001→中国联通）属于对真实数据的推断，也不是默认值。
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

    -- 纳入 AT 全局互斥锁：原先是三个写者之一，无锁直连串口
    local cmd = at_locked(string.format("sms_tool -d %s -s %s -j recv 2>/dev/null", port, storage))
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
    -- 这条由机器人主循环每 12 秒无条件调用，是全局风险最高的一处 AT 访问：
    -- 原先是无锁 + 无超时，一旦挂住整个机器人事件循环永久停止（pcall 拦不住 C 层 read）。
    local st_raw = core.exec(at_locked(string.format("sms_tool -d %s -s ME status 2>/dev/null", port), 2))
    -- 必须区分"读不到"与"数量为 0"：
    -- AT 锁争用时包装器返回 AT_BUSY，超时或端口异常时返回空串。
    -- 若把这些当成 used=0，就会把台账清零，下一轮成功读取时
    -- 全部历史短信都会被判定为新短信并逐条推送（短信轰炸）。
    local used_str = st_raw and st_raw:match("used:%s*(%d+)")
    if not used_str then
        return {}
    end
    local cur_used = tonumber(used_str) or 0

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

return M
