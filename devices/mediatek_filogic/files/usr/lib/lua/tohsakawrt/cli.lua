-- TohsakaWrt Unified CLI Engine in Lua
local M = {}

local core = require("tohsakawrt.core")
local sys = require("tohsakawrt.system")
local modem = require("tohsakawrt.modem")
local clash = require("tohsakawrt.clash")
local tg = require("tohsakawrt.tg")

function M.status()
    local uplink = sys.uplink_status()
    local temp = sys.cpu_temp()
    local pub_ip = sys.public_ip()
    local wan_ip = sys.wan_ip()
    local usb_ip = sys.usb0_ip()
    local m_info = modem.info()

    print("==========================================")
    print("       TohsakaWrt 智能网关系统状态 (Lua)  ")
    print("==========================================")
    print(string.format("主力上网出口 : %s (%s)", uplink.type, uplink.dev))
    print(string.format("CPU 实时温度 : %s", temp))
    print(string.format("外网公网出口 : %s", pub_ip))
    print(string.format("有线宽带 IP  : %s", wan_ip))
    print(string.format("5G 模组 IP   : %s", usb_ip))
    print(string.format("5G 蜂窝制式  : %s (%s)", m_info.oper, m_info.band))
    print("==========================================")
end

function M.temp()
    print("CPU Temperature: " .. sys.cpu_temp())
end

function M.uplink(args)
    args = args or {}
    local sub = args[1] or "status"
    if sub == "status" then
        local u = sys.uplink_status()
        print(string.format("ACTIVE:%s|%s", u.type, u.dev))
    elseif sub == "set" then
        local target = args[2]
        local res = sys.switch_uplink(target)
        print(res)
    else
        print("Usage: tohsakawrt uplink {status | set wan | set 5g}")
    end
end

function M.modem(args)
    args = args or {}
    local sub = args[1]
    if sub == "status" or not sub or sub == "" then
        local m = modem.info()
        print("Modem: Quectel RM500Q-GL")
        print("Port: /dev/ttyUSB2")
        print("Operator: " .. m.oper)
        print("Band: " .. m.band)
        print("Mode: " .. m.mode)
        print("Cellular IP: " .. m.sim_ip)
    elseif sub == "at" then
        local cmd = table.concat(args, " ", 2)
        local out = modem.at(cmd)
        if out then io.write(out) end
    elseif sub == "heal" then
        local res = modem.keepalive_and_heal()
        print("Heal status: " .. res)
    else
        print("Usage: tohsakawrt modem {status | heal | at <cmd>}")
    end
end

function M.direct(args)
    args = args or {}
    local sub = args[1] or "list"
    if sub == "list" then
        local list = clash.direct_list()
        if #list == 0 then
            print("EMPTY")
        else
            for i, it in ipairs(list) do
                print(string.format("%d|%s", i, it))
            end
        end
    elseif sub == "add" then
        local target = args[2]
        if not target or target == "" then
            print("ERROR:empty_target")
        else
            print(clash.direct_add(target))
        end
    elseif sub == "del" then
        local target = args[2]
        if not target or target == "" then
            print("ERROR:empty_arg")
        else
            print(clash.direct_del(target))
        end
    else
        print("Usage: tohsakawrt direct {list | add <target> | del <target>}")
    end
end

function M.notify(args)
    args = args or {}
    local text = table.concat(args, " ")
    if text == "" then
        print("Usage: tohsakawrt notify <text>")
        return
    end
    tg.send_msg(text)
end

function M.main(argv)
    argv = argv or {}
    local cmd = argv[1] or ""
    local rest = {}
    for i = 2, #argv do
        table.insert(rest, argv[i])
    end

    if cmd == "status" then
        M.status()
    elseif cmd == "uplink" then
        M.uplink(rest)
    elseif cmd == "modem" then
        M.modem(rest)
    elseif cmd == "direct" then
        M.direct(rest)
    elseif cmd == "temp" then
        M.temp()
    elseif cmd == "notify" then
        M.notify(rest)
    else
        print("TohsakaWrt 统一管理控制台 (Lua Engine)")
        print("用法: tohsakawrt <command> [arguments...]")
        print("")
        print("可用命令：")
        print("  uplink   [status | set wan | set 5g]   主力上网出口平滑倒换")
        print("  direct   [add | del | list]            OpenClash 直连白名单管理")
        print("  modem    [status | heal | at <cmd>]    5G 蜂窝模组状态与自愈")
        print("  temp     [status]                      CPU 温度查询")
        print("  notify   <text>                        向 Telegram 发送通知")
        print("  status                                 查看系统综合看板")
        print("  watch    [all | temp | service | heal] 执行周期巡检看门狗")
        print("")
    end
end

if arg and arg[0] and (arg[0]:find("cli.lua") or arg[0]:find("tohsakawrt")) then
    M.main(arg)
end

return M
