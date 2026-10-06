#!/bin/sh
# Copyright (C) 2023 Siriling <siriling@qq.com>

#脚本目录
SCRIPT_DIR="/usr/share/modem"
source "${SCRIPT_DIR}/modem_debug.sh"

#发送at命令
# $1 AT串口
# $2 AT命令
# P0 fix: 全局 AT 互斥。BusyBox flock 不支持 -w，用 -n 轮询实现有界等待。
if command -v flock >/dev/null 2>&1; then
	exec 9>"/var/lock/modem-at.lock"
	_wait=0
	while ! flock -n 9; do
		_wait=$((_wait + 1))
		if [ "$_wait" -ge 8 ]; then
			echo "AT_BUSY"
			exit 1
		fi
		sleep 1
	done
fi

at "$1" "$2"
