-- TohsakaWrt OpenClash & Whitelist Module (High Performance)
local M = {}

local core = require("tohsakawrt.core")
local json = require("luci.jsonc")

local API_BASE = "http://127.0.0.1:9090"

-- Keep quoting local so offline tests that stub core still exercise this file's real quoting logic.
local function shell_quote(value)
    return "'" .. tostring(value):gsub("[\n\r\t]", " "):gsub("'", "'\\''") .. "'"
end

local function valid_target(t)
    return type(t) == "string" and (t:match("^[%w_%.%-%:]+$") or t:match("^[%w_%.%-%:]+/%d+$"))
end

local function api_get(endpoint, timeout)
    timeout = timeout or 3
    local cmd = string.format("curl -s -m %d '%s%s'", timeout, API_BASE, endpoint)
    local out = core.exec(cmd)
    if not out or out == "" then return nil end
    return json.parse(out)
end

local function api_patch(endpoint, data, timeout)
    timeout = timeout or 3
    local body = json.stringify(data)
    -- 必须走 shell_quote：原先用裸 '-d '%s'' 包裹，body 里的单引号会直接逃出引号，
    -- 形成命令注入（例如 mode = "rule'; sleep 999; #" 可让机器人卡 999 秒）。
    local cmd = string.format("curl -s -m %d -X PATCH -H 'Content-Type: application/json' -d %s '%s%s'", timeout, shell_quote(body), API_BASE, endpoint)
    return core.exec(cmd)
end

function M.status()
    local res = api_get("/version", 2)
    if res and res.version then
        return { running = true, version = res.version, core = "Mihomo" }
    end
    local pid = core.exec_line("pidof mihomo 2>/dev/null || pidof clash 2>/dev/null")
    if pid ~= "" then
        return { running = true, version = "API未响应", core = "存活" }
    end
    return { running = false, version = "未运行", core = "已停止" }
end

function M.full_status()
    local pid = core.exec_line("pidof mihomo 2>/dev/null || pidof clash 2>/dev/null")
    local enabled = core.get_uci("openclash", "@openclash[0]", "enable", "0")
    local v_cmd = "/etc/openclash/clash -v 2>/dev/null | head -n1"
    local version = core.exec_line(v_cmd)
    if version == "" then
        local st = M.status()
        version = st.version
    end

    local ports = core.exec_line([=[netstat -tln 2>/dev/null | grep -E ':(7874|7890|7892|7895|9090)[[:space:]]' | awk '{print $4}' | sed 's/.*://' | sort -nu | tr '\n' ' ']=])
    if ports == "" then ports = "未检测到" end

    return {
        enabled = (enabled == "1"),
        running = (pid ~= ""),
        pid = (pid ~= "" and pid or "无"),
        version = version,
        ports = ports
    }
end

function M.mode()
    local res = api_get("/configs", 2)
    if res and res.mode then
        return res.mode
    end
    return "unknown"
end

-- 白名单：mode 来自客户端上报的 callback_data，必须校验后才允许落到 shell。
-- 同文件的 direct_add 早就有 valid_target 校验，这里原先缺失。
local VALID_MODES = { rule = true, global = true, direct = true }

function M.set_mode(mode)
    mode = tostring(mode or ""):match("^%s*(.-)%s*$") or ""
    if not VALID_MODES[mode] then
        return nil, "invalid_mode"
    end
    api_patch("/configs", { mode = mode }, 3)
    return mode
end

function M.restart()
    core.exec("/etc/init.d/openclash restart >/dev/null 2>&1 &")
end

local function resolve_node(proxies, name, depth)
    depth = depth or 0
    if depth > 5 then return name, "" end
    local p = proxies[name]
    if not p then return name, "" end
    if (p.type == "Selector" or p.type == "URLTest" or p.type == "Fallback") and p.now and p.now ~= name then
        return resolve_node(proxies, p.now, depth + 1)
    end
    local delay_str = ""
    if p.history and #p.history > 0 then
        local d = p.history[#p.history].delay
        if d and d > 0 then delay_str = tostring(d) .. "ms" end
    end
    return name, delay_str
end

function M.nodes_info()
    local data = api_get("/proxies", 3)
    if not data or not data.proxies then
        return {}
    end

    local groups = {"🚀 默认代理", "💎 自建专线", "🍀 Google", "🤖 ChatGPT", "📲 Telegram", "📹 YouTube", "👨🏿‍💻 GitHub"}
    local results = {}
    for _, g in ipairs(groups) do
        local p = data.proxies[g]
        if p then
            local real_name, delay = resolve_node(data.proxies, p.now)
            table.insert(results, {
                group = g,
                now = p.now or "无",
                real = real_name or "无",
                delay = delay
            })
        end
    end
    return results
end

function M.test_nodes()
    core.exec("curl -s -m 4 'http://127.0.0.1:9090/group/%E2%99%BB%EF%B8%8F%20%E9%A6%99%E6%B8%AF%E8%87%AA%E5%8A%A8/delay?url=http%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204&timeout=2500' >/dev/null 2>&1 &")
    core.exec("curl -s -m 4 'http://127.0.0.1:9090/group/%E2%99%BB%EF%B8%8F%20%E7%BE%8E%E5%9B%BD%E8%87%AA%E5%8A%A8/delay?url=http%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204&timeout=2500' >/dev/null 2>&1 &")
end

function M.proxy_delay(group_name)
    group_name = group_name or "🚀 默认代理"
    -- Check cached history from /proxies first to avoid network stall
    local data = api_get("/proxies", 2)
    if data and data.proxies then
        local p = data.proxies[group_name]
        if p then
            if p.history and #p.history > 0 then
                local d = p.history[#p.history].delay
                if d and d > 0 then return d end
            end
            if p.now and data.proxies[p.now] then
                local real_p = data.proxies[p.now]
                if real_p.history and #real_p.history > 0 then
                    local d = real_p.history[#real_p.history].delay
                    if d and d > 0 then return d end
                end
            end
        end
    end

    -- Fast active probe
    local encoded = string.gsub(group_name, "([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local cmd = string.format("curl -s -m 2 'http://127.0.0.1:9090/proxies/%s/delay?url=http%%3A%%2F%%2Fcp.cloudflare.com%%2Fgenerate_204&timeout=1500'", encoded)
    local raw = core.exec(cmd)
    if raw and raw ~= "" then
        local d = json.parse(raw)
        if d and d.delay and d.delay > 0 then
            return d.delay
        end
    end
    return nil
end

-- 直连白名单统一到新实现 /usr/bin/tohsakawrt-clash-direct。
-- 它把规则写进 /etc/openclash/config/config.yaml 的 TG_DIRECT_RULES 段 —— 那才是 OpenClash
-- 实际加载的模块配置。旧实现 /usr/bin/tohsaka-direct 写的是 /etc/openclash/tg_direct_rules.list，
-- 该文件不被任何配置 include（已在设备上 grep 确认），只有它顺带同步的运行态 yaml 会生效，
-- 于是出现"清单里看不到刚加的规则、撤销了也不生效"的分叉：实测两套清单内容已不一致
-- （旧：fxxk.dedyn.io；新：www.workbuddy.ai + fxxk.dedyn.io）。
local DIRECT_BIN = "/usr/bin/tohsakawrt-clash-direct"

function M.direct_list()
    local raw = core.exec(DIRECT_BIN .. " list 2>/dev/null") or ""
    local list = {}
    for line in raw:gmatch("[^\r\n]+") do
        local d = line:match("^%s*(.-)%s*$")
        if d ~= "" and not d:match("^#") then
            table.insert(list, d)
        end
    end
    return list
end

-- 只取首行判定：脚本在热重载失败时会额外输出一行 RELOAD_FAILED:<code>，
-- 用整体精确比较会把"已写入成功"误判成失败（进而"重试→ALREADY→又判失败"，
-- 主路径变成既无法成功也无法撤销）。
local function direct_run(verb, target)
    if not valid_target(target) then return "ERROR:invalid_target" end
    local raw = core.exec(DIRECT_BIN .. " " .. verb .. " " .. shell_quote(target) .. " 2>/dev/null") or ""
    local first = raw:match("^([^\r\n]+)") or ""
    if raw:find("RELOAD_FAILED:", 1, true) then
        return first .. "|RELOAD_FAILED"
    end
    return first
end

function M.direct_add(target)
    return direct_run("add", target)
end

function M.direct_del(target)
    return direct_run("del", target)
end

return M
