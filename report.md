# Bark 推送 HTML 标签泄漏修复报告

## 改动清单

- `devices/mediatek_filogic/files/usr/lib/tohsakawrt/common.sh:147-149`：新增 `html_to_text()`。它先移除 HTML 标签，再按 `&lt;`、`&gt;`、`&amp;` 的顺序还原实体；原有 `html_escape()` 保持不变。
- `devices/mediatek_filogic/files/usr/lib/tohsakawrt/common.sh:56-57`：`push_bark()` 在 `printf '%b'` 处理换行转义后，对标题和正文统一调用 `html_to_text()`，避免 Bark 通知显示 Telegram HTML 标签和实体。
- `devices/mediatek_filogic/files/usr/bin/tohsakawrt-service-watch:540,561`：两处高带宽告警直接传 `$ALERT_BODY` / `$REPORT_BODY`，移除重复的手工去标签处理。

## 验证 1：Shell 语法检查

执行命令：

```sh
sh -n devices/mediatek_filogic/files/usr/lib/tohsakawrt/common.sh
sh -n devices/mediatek_filogic/files/usr/bin/tohsakawrt-service-watch
```

两条 `sh -n` 命令本身均无输出、退出码均为 0。捕获到的终端输出（状态行由验证命令打印）：

```text
common.sh sh -n exit: 0
service-watch sh -n exit: 0
```

## 验证 2：Bark curl 桩

用 `/tmp/verify_bark_html.sh` source `common.sh`，将 `curl` 替换为捕获 title/body 参数的桩。输入包含 `<b>`、`<code>`、`&gt;` 和字面 `\n`。脚本原始输出：

```text
TITLE_BEGIN
标题
TITLE_END

BODY_BEGIN
粗体 > x&y
下一行
BODY_END
CHECK no_lt: PASS
CHECK no_gt_entity: PASS
CHECK real_newline: PASS
```

输出表明标题和正文中的标签已去除、`&gt;` 已还原，且 `\n` 已变为真换行；检查确认正文不含 `<` 和 `&gt;`。

## 仍未验证 / 不确定项

- 未在 Cudy TR3000 的 BusyBox ash 环境上运行，也未向真实 Bark 服务发送通知；验证只覆盖本地 `/bin/sh` 和 curl 参数桩。
- 未运行仓库测试套件；本任务按要求只执行了两条语法检查和指定的桩验证。

总结：Bark 推送现在会先把 Telegram HTML 标题和正文转换为纯文本，再提交给 Bark。
