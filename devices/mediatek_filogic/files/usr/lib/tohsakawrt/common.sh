#!/bin/sh
# 被 source 使用，不直接执行。

format_duration() {
    local sec="${1:-0}"
    local hours=$((sec / 3600))
    local minutes=$(((sec % 3600) / 60))
    local seconds=$((sec % 60))

    if [ "$hours" -gt 0 ]; then
        echo "${hours}小时${minutes}分钟"
    elif [ "$minutes" -gt 0 ]; then
        echo "${minutes}分钟${seconds}秒"
    else
        echo "${seconds}秒"
    fi
}

format_traffic_bytes() {
    local bytes="${1:-0}"
    if [ "$bytes" -ge 1073741824 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2f GB", b/1073741824}'
    elif [ "$bytes" -ge 1048576 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1f MB", b/1048576}'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1f KB", b/1024}'
    else
        echo "${bytes} B"
    fi
}

format_traffic_speed() {
    local bytes="${1:-0}"
    local mb="$(awk -v b="$bytes" 'BEGIN {printf "%.1f MB/s", b/1048576}')"
    local mbps="$(awk -v b="$bytes" 'BEGIN {printf "%.0f Mbps", (b*8)/1000000}')"
    echo "${mb} (${mbps})"
}

rotate_log() {
    local logfile="$1"
    local max_lines="${2:-200}"
    if [ -f "$logfile" ]; then
        local count
        count="$(wc -l < "$logfile" 2>/dev/null)"
        if [ "${count:-0}" -gt "$((max_lines + 50))" ]; then
            tail -n "$max_lines" "$logfile" > "${logfile}.tmp" 2>/dev/null && mv "${logfile}.tmp" "$logfile"
        fi
    fi
}

push_bark() {
    local bark_key="${BARK_KEY:-}"
    local bark_api="${BARK_API:-https://api.day.app/push}"
    local title body level sound
    [ -n "$bark_key" ] || return 0
    title="$(printf '%b' "$1")"
    body="$(printf '%b' "$2")"
    level="$3"
    sound="$4"

    curl -m 10 -fsS \
        -X POST \
        -d "device_key=${bark_key}" \
        --data-urlencode "title=${title}" \
        --data-urlencode "body=${body}" \
        --data-urlencode "group=TohsakaWrt 智能网关" \
        -d "level=${level}" \
        -d "sound=${sound}" \
        "$bark_api" >/dev/null 2>&1
}

# ---- 告警附带的操作按钮 ----
# callback_data 必须是机器人已认识的动作（见 bot.lua 的 handle_callback）：
#   refresh_status / refresh_modem / open_uplink_menu / re_ping / test_nodes
TG_KB_STATUS='{"inline_keyboard":[[{"text":"🩺 查状态","callback_data":"refresh_status"}]]}'
TG_KB_STATUS_UPLINK='{"inline_keyboard":[[{"text":"🩺 查状态","callback_data":"refresh_status"},{"text":"🔀 切换出口","callback_data":"open_uplink_menu"}]]}'
TG_KB_STATUS_MODEM='{"inline_keyboard":[[{"text":"🩺 查状态","callback_data":"refresh_status"},{"text":"📶 查模组","callback_data":"refresh_modem"}]]}'
TG_KB_STATUS_PING='{"inline_keyboard":[[{"text":"🩺 查状态","callback_data":"refresh_status"},{"text":"📡 重新体检","callback_data":"re_ping"}]]}'
TG_KB_STATUS_NODES='{"inline_keyboard":[[{"text":"🩺 查状态","callback_data":"refresh_status"},{"text":"🌐 测节点","callback_data":"test_nodes"}]]}'

# 按告警正文自动挑选按钮；send_tg 传 "-" 表示这条不带按钮
tg_auto_kb() {
    case "$1" in
        *主出口探测超时*|*网络异常*|*已上线*) echo "$TG_KB_STATUS_UPLINK" ;;
        *5G*降级*|*5G*恢复*|*热备链路*|*模组*) echo "$TG_KB_STATUS_MODEM" ;;
        *OpenClash*|*核心*) echo "$TG_KB_STATUS_NODES" ;;
        *高温*|*温度*|*高带宽*) echo "$TG_KB_STATUS_PING" ;;
        *) echo "$TG_KB_STATUS" ;;
    esac
}

send_tg() {
    local text="$(printf '%b' "$1")"
    local parse_mode="${2:-}"
    local reply_markup="${3:-}"
    local tg_token tg_chat tg_enabled
    tg_token="$(uci -q get tohsakawrt-tgbot.main.token)"
    tg_chat="$(uci -q get tohsakawrt-tgbot.main.chat_id)"
    tg_enabled="$(uci -q get tohsakawrt-tgbot.main.enabled)"

    # 未配置时也必须留下痕迹：旧写法 `... || return 0` 会"什么都不发却报告成功"，
    # 导致调用方以为已投递（06-07 的告警演示就栽在这里）
    if [ "$tg_enabled" != "1" ] || [ -z "$tg_token" ] || [ -z "$tg_chat" ]; then
        logger -t TohsakaWrt-Tg "send_tg 未发送：机器人未启用或凭据缺失（enabled=${tg_enabled}）"
        return 1
    fi

    if [ -z "$reply_markup" ]; then
        reply_markup="$(tg_auto_kb "$text")"
    fi
    if [ "$reply_markup" = "-" ]; then
        reply_markup=""
    fi

    set -- -m 10 -fsS \
        -X POST \
        "https://api.telegram.org/bot${tg_token}/sendMessage" \
        -d "chat_id=${tg_chat}" \
        --data-urlencode "text=${text}"
    if [ -n "$parse_mode" ]; then
        set -- "$@" -d "parse_mode=${parse_mode}"
    fi
    if [ -n "$reply_markup" ]; then
        set -- "$@" -d "reply_markup=${reply_markup}"
    fi

    # 投递校验：curl 成功不等于送达，必须看 Telegram 是否回 ok:true；
    # 失败记日志并重试一次（06-07 曾出现 curl 退出码 0 但用户收不到的情况）
    local attempt reply
    for attempt in 1 2; do
        reply="$(curl "$@" 2>&1)"
        case "$reply" in
            *'"ok":true'*)
                return 0
                ;;
        esac
        logger -t TohsakaWrt-Tg "send_tg 投递失败（第 ${attempt} 次）: $(printf '%s' "$reply" | tr -d '\n' | cut -c1-200)"
        sleep 1
    done
    return 1
}

html_escape() {
    printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

get_cpu_temp() {
    if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        awk '{printf "%.1f°C", $1/1000}' /sys/class/thermal/thermal_zone0/temp
    else
        echo "未知"
    fi
}

get_active_dev() {
    ip route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1
}

get_active_uplink() {
    local dev="$(get_active_dev)"
    case "$dev" in
        usb0) echo "5g" ;;
        eth0) echo "wan" ;;
        *) echo "${dev:-unknown}" ;;
    esac
}

get_modem_cellular_info() {
    local at_port="${1:-/dev/ttyUSB2}"
    local modem_at="${2:-/usr/share/modem/modem_at.sh}"
    if [ ! -e "$at_port" ] || [ ! -x "$modem_at" ]; then
        echo "|||未检测到模组"
        return
    fi

    local cgpaddr qnwinfo
    if command -v timeout >/dev/null 2>&1; then
        cgpaddr="$(timeout 3 sh "$modem_at" "$at_port" 'AT+CGPADDR=1' 2>/dev/null | tr -d '\r' | grep '+CGPADDR:' | head -n 1)"
        qnwinfo="$(timeout 3 sh "$modem_at" "$at_port" 'AT+QNWINFO' 2>/dev/null | tr -d '\r' | grep '+QNWINFO:' | head -n 1)"
    else
        cgpaddr="$(sh "$modem_at" "$at_port" 'AT+CGPADDR=1' 2>/dev/null | tr -d '\r' | grep '+CGPADDR:' | head -n 1)"
        qnwinfo="$(sh "$modem_at" "$at_port" 'AT+QNWINFO' 2>/dev/null | tr -d '\r' | grep '+QNWINFO:' | head -n 1)"
    fi

    local sim_ip="$(printf '%s\n' "$cgpaddr" | awk -F'"' '{print $2}' | awk -F',' '{print $1}')"
    local plmn="$(printf '%s\n' "$qnwinfo" | awk -F'"' '{print $4}')"
    local band="$(printf '%s\n' "$qnwinfo" | awk -F'"' '{print $6}')"
    local mode="$(printf '%s\n' "$qnwinfo" | awk -F'"' '{print $2}')"

    local oper
    case "$plmn" in
        46001|46006|46009) oper="中国联通" ;;
        46000|46002|46004|46007|46008) oper="中国移动" ;;
        46003|46005|46011|46012) oper="中国电信" ;;
        46015) oper="中国广电" ;;
        *) oper="${plmn:-未知运营商}" ;;
    esac

    echo "${sim_ip:-未获取}|${oper}|${band:-未知频段}|${mode:-未知}"
}

get_wan_public_ip() {
    local ipip
    ipip="$(curl -s -m 2 http://myip.ipip.net 2>/dev/null)"
    if [ -n "$ipip" ]; then
        local ip="$(echo "$ipip" | awk '{print $2}' | sed 's/当前//; s/IP：//')"
        local loc="$(echo "$ipip" | sed -n 's/.*来自于：//p' | awk '{$1=$1; print}')"
        echo "${ip:-未知} (${loc:-未知})"
    else
        echo "未获取到"
    fi
}

