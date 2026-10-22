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

    local function clean_text(v)
        local s = tostring(v or ""):gsub("[\r\n]", " ")
        return s:match("^%s*(.-)%s*$")
    end
    local function is_blank(sender, content)
        return clean_text(sender) == "" and clean_text(content) == ""
    end
    local function display_sender(v)
        local s = clean_text(v)
        return s ~= "" and s or "未知发件人"
    end
    local function display_ts(v)
        local s = clean_text(v)
        return s ~= "" and s or "未知时间"
    end

    -- 原始最大索引（含多段短信的每一段）。sms_poll_new 用它推进游标：
    -- 只按组装后的消息索引会漏掉"第二段到了但第一段索引没变"的情况。
    local raw_max_index = -1
    for _, m in ipairs(msgs) do
        local idx = tonumber(m.index) or -1
        if idx > raw_max_index then raw_max_index = idx end
    end

    local multipart = {}
    local assembled = {}

    for _, m in ipairs(msgs) do
        local content = tostring(m.content or "")
        local total = tonumber(m.total)
        if m.reference and m.part and total and total > 1 then
            local key = string.format("%s_%s", clean_text(m.sender), tostring(m.reference))
            local mp = multipart[key]
            if not mp then
                mp = {
                    sender = m.sender,
                    timestamp = m.timestamp,
                    parts = {},
                    total = total,
                    sort_time = parse_sms_ts(m.timestamp),
                    first_index = m.index,
                    last_index = m.index
                }
                multipart[key] = mp
            end
            mp.parts[tonumber(m.part)] = content
            if (tonumber(m.index) or -1) > (tonumber(mp.last_index) or -1) then
                mp.last_index = m.index
            end
            if clean_text(mp.sender) == "" and clean_text(m.sender) ~= "" then mp.sender = m.sender end
            if clean_text(mp.timestamp) == "" and clean_text(m.timestamp) ~= "" then mp.timestamp = m.timestamp end
        elseif not is_blank(m.sender, content) then
            table.insert(assembled, {
                index = m.index,
                sender = display_sender(m.sender),
                timestamp = display_ts(m.timestamp),
                content = content,
                code = extract_sms_code(content),
                sort_time = parse_sms_ts(m.timestamp)
            })
        end
    end

    for _, mp in pairs(multipart) do
        -- 只输出"所有分段都到齐"的多段短信。缺段时输出半截/空内容，
        -- 既会误导用户，也会让轮询把同一条短信反复当成新消息。
        local complete = true
        local full_text = ""
        for p = 1, mp.total do
            local part = mp.parts[p]
            if part == nil then complete = false; break end
            full_text = full_text .. part
        end
        if complete and not is_blank(mp.sender, full_text) then
            table.insert(assembled, {
                index = mp.last_index or mp.first_index,
                sender = display_sender(mp.sender),
                timestamp = display_ts(mp.timestamp),
                content = full_text,
                code = extract_sms_code(full_text),
                sort_time = mp.sort_time
            })
        end
    end

    -- 按存储索引倒序：索引由模组按"收到顺序"分配，跨时区/换卡都可靠。
    -- 时间戳来自短信中心，格鲁吉亚 +04 的 19:25 和香港 +08 的 22:32 直接比较会倒序，
    -- 导致最新收到的短信被排到旧短信后面（/sms 只取前 3 条时就看不到）。
    table.sort(assembled, function(a, b)
        local ai, bi = tonumber(a.index) or -1, tonumber(b.index) or -1
        if ai ~= bi then return ai > bi end
        return (a.sort_time or 0) > (b.sort_time or 0)
    end)

    local result = assembled
    if limit and limit > 0 and #assembled > limit then
        local sliced = {}
        for i = 1, limit do
            table.insert(sliced, assembled[i])
        end
        result = sliced
    end
    -- 带外字段：原始最大索引（ipairs 不会遍历到它）
    result.max_index = raw_max_index
    return result
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
    local last_index = tonumber(core.get_state("sms_last_index", "-1")) or -1
    local last_sig = core.get_state("sms_last_sig", "")

    -- 必须每轮都拿列表：只看 used 计数会漏掉
    --   ① 数量没变但换了内容（删除一条又来一条）
    --   ② 换卡/换 profile 后存储索引变化
    --   ③ 跨时区的时间戳倒序（格鲁吉亚 +04 的 19:25 比香港 +08 的 22:32 "看起来"更早）
    -- 列表本身是 sms_tool -j recv 的全量解析，多一次 AT 读换正确性，值得。
    local all_sms = M.sms_list("ME", 20)
    if not all_sms then return {} end

    local function sms_sig(sms)
        if not sms then return "" end
        local content = tostring(sms.content or "")
        -- 不要直接用正文做签名：core.get_state 会 trim 首尾空白，而短信正文可能以
        -- 空格/换行结尾（#SIMWorld 实测结尾两个空格）。那样写进 state 的签名会被
        -- 截短，读回来永远不等于新算的签名，兜底分支就会每 12 秒把同一条短信重推。
        -- 改成"长度 + 滚动哈希"，末尾是数字，trim 不会改变它。
        local h = 0
        for i = 1, #content do
            h = (h * 131 + content:byte(i)) % 2147483647
        end
        return string.format("S:%s|T:%s|L:%d|H:%d",
            tostring(sms.sender), tostring(sms.timestamp), #content, h)
    end

    local newest, max_ts = nil, last_ts
    for _, sms in ipairs(all_sms) do
        if not newest or (tonumber(sms.index) or -1) > (tonumber(newest.index) or -1) then
            newest = sms
        end
        if sms.sort_time and sms.sort_time > max_ts then max_ts = sms.sort_time end
    end
    -- 原始最大索引（含多段短信的每一段）：缺段时组装列表里没有这条，
    -- 但游标必须推进，否则每一轮都会重新检查同一条不完整短信。
    local max_index = tonumber(all_sms.max_index)
    if not max_index then
        max_index = newest and (tonumber(newest.index) or -1) or -1
    end
    local cur_sig = sms_sig(newest)
    local saw_new_index = max_index > last_index

    local function remember()
        core.set_state("sms_last_used", tostring(cur_used))
        core.set_state("sms_last_ts", tostring(max_ts))
        core.set_state("sms_last_index", tostring(max_index))
        core.set_state("sms_last_sig", cur_sig)
    end

    if last_index < 0 or last_used < 0 then
        -- 首次启动/老版本升级/台账半写：只打台账，不补推历史短信，避免刷屏。
        remember()
        return {}
    end

    if max_index < last_index then
        -- 换卡/清空/存储索引回退：重置台账，同样不补推。
        remember()
        return {}
    end

    local function has_content(sms)
        return tostring(sms and sms.content or ""):gsub("%s+", "") ~= ""
    end

    local new_sms = {}
    -- 主判据：存储索引比上次大。索引是模组分配的单调值，不受时区和换卡影响。
    -- 空短信（状态报告/静默短信/空 PDU）没有可展示内容，不推送，但索引照样推进。
    for _, sms in ipairs(all_sms) do
        if (tonumber(sms.index) or -1) > last_index and has_content(sms) then
            new_sms[#new_sms + 1] = sms
        end
    end
    -- 兜底：索引没变但计数增加或最新一条的签名变了（多段短信的后续分段/索引复用）。
    if #new_sms == 0 and (cur_used > last_used or cur_sig ~= last_sig)
        and newest and has_content(newest) then
        new_sms[1] = newest
    end

    if #new_sms > 0 or saw_new_index then
        -- 即使新索引对应的是一条空/不完整短信（没有可推送内容），也要推进游标，
        -- 否则它会一直停留在 last_index 上，每轮重复检查。
        remember()
    elseif cur_used ~= last_used then
        -- 没有新短信但计数变化（删除/清空）：只同步计数，不动索引与签名。
        core.set_state("sms_last_used", tostring(cur_used))
    end

    return new_sms
end

return M
