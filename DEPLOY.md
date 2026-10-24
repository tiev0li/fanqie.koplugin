# 番茄小说 KOReader 插件 — 真机部署指南

适用版本：**v2.3.0**（含内置番茄APP书源）。部署对象为 KOReader 电子墨水屏设备（Kindle / Kobo / PocketBook / Android 阅读器）。

---

## 1. 前置要求

| 项目 | 要求 |
|------|------|
| KOReader | 2023.x 及以上（标准构建自带 luasocket / ssl / lfs，无需额外依赖） |
| 网络 | 设备可访问以下番茄域名：`api5-normal-sinfonlineb.fqnovel.com`、`novelfm-hl.snssdk.com`、`api.fanqiesdk.com`、`fanqienovel.com`、`log.snssdk.com`（设备注册） |
| 账号 | **无需任何账号**。内置番茄APP源默认启用且排最前，扫码登录仅在使用书架/进度同步功能时才需要 |

> ⚠️ 如果路由器开了广告过滤/DNS 劫持（如 AdGuard Home、OpenWrt 去广告规则），`log.snssdk.com` 可能被拦截，导致设备注册失败——表现为目录/搜索/发现正常、正文报「设备池为空」。

## 2. 安装位置

插件目录名必须是 `fanqie.koplugin`（以 `.koplugin` 结尾），放入 KOReader 安装目录下的 `plugins/` 文件夹：

| 设备 | 插件目录 |
|------|----------|
| Kindle | `/mnt/us/koreader/plugins/fanqie.koplugin` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/fanqie.koplugin` |
| PocketBook | `/mnt/ext1/applications/koreader/plugins/fanqie.koplugin` |
| Android | 内置存储 `koreader/plugins/`（以设备上已有插件的所在目录为准） |

不确定路径时：在 KOReader 的文件管理器里找任意已装插件（xxx.koplugin）所在的目录即可。

## 3. 部署方式

### 方式一：USB 大容量存储（最简单）

1. 设备通过 USB 连接电脑，选择「USB 传输模式」（Kindle 需在 KSM/菜单中允许）
2. 将整个 `fanqie.koplugin` 文件夹复制到上述 `plugins/` 目录
3. 弹出设备，重启 KOReader

> Windows 压缩包解压注意：确保 `plugins/` 下直接是 `fanqie.koplugin/` 文件夹，不要多套一层目录。

### 方式二：SSH / scp（Kindle / Kobo，已开 USBNetwork 或 Wi-Fi SSH）

```bash
# Kindle（IP 以路由器分配为准）
scp -r fanqie.koplugin root@192.168.1.100:/mnt/us/koreader/plugins/

# Kobo
scp -r fanqie.koplugin root@192.168.1.101:/mnt/onboard/.adds/koreader/plugins/
```

### 方式三：ADB（Android 阅读器）

```bash
adb push fanqie.koplugin /sdcard/koreader/plugins/
```

## 4. 升级已有安装

1. **备份插件目录内的 `config.lua`**（如有）——升级会覆盖整个插件目录
2. 用新版 `fanqie.koplugin` 覆盖旧目录，恢复 `config.lua`
3. 重启 KOReader

数据安全说明：书架缓存、章节缓存、Cookie、**设备池**（`app_device_pool.txt`）、书源配置都存放在 **KOReader 数据目录**（与 `settings.reader.lua` 同级），不在插件目录内，覆盖升级不会丢失。

首次启动会自动执行设置迁移，**无需任何手动操作**：

- v3：向已有的书源配置补入 `fanqie_app = { enabled=true, order=0 }`；
- v4：清除已移除书源（晴天聚合 / 大灰狼）的残留配置，包括其中保存的账号、密码与 token。

全新安装则直接落盘默认书源配置（官方 App 协议 + 内置番茄 APP 源）。

## 5. 部署后验证

按顺序检查：

1. **版本确认**：菜单 → 番茄小说 → 关于 → 应显示 v2.3.0，特性列表含「内置番茄APP源」
2. **新入口**：菜单 → 番茄小说 → 应出现「搜索书籍」「发现书籍」两个新菜单项
3. **搜索**：搜索书籍 → 输入书名（如「十日终焉」）→ 应返回结果列表，点击进入书籍详情
4. **正文**：书籍详情 → 开始阅读 → 能看到正文（首次会自动注册设备，稍等几秒）
5. **设备池**：设置 → 书源管理 → 番茄APP（内置）→ 应显示「设备池: 1 台 (xxxxxx...)」
6. **目录回退**：随便打开一本书的章节目录 → 正常列出章节（官方接口失败时自动走内置源）

## 6. 常见问题

### Q1：正文报「设备池为空」或「设备注册失败」

- 检查 `log.snssdk.com` 是否被路由器 DNS 拦截（见第 1 节注意事项）
- 手动补注册：设置 → 书源管理 → 番茄APP（内置）→ 「注册新设备」
- 目录/搜索/发现不依赖设备注册，这些功能不受影响

### Q2：书源列表里没有「番茄APP（内置）」

- 确认插件已更新到 v2.3.0（看「关于」）
- 首次启动已完成 v3 迁移；若仍未出现，进入 设置 → 书源管理 查看完整列表（禁用状态的源也在列表中，点击启用即可）

### Q3：批量下载很慢

内置源默认限流 **1 次/秒**（防封保护）。如需提速，在插件目录的 `config.lua`（可从 `config.example.lua` 复制）中调整：

```lua
sources = {
    fanqie_app = {
        enabled = true,
        rate_limit = { max_requests = 2, window_seconds = 1 },
    },
},
```

### Q4：如何看日志

- KOReader 标准日志：数据目录下的 `crash.log`，插件日志以 `[FanQie]` 前缀区分
- 需要更详细日志时，在 `config.lua` 中开启 `debug = { log_request = true, log_response = true }`

### Q5：回滚到旧版本

删除/覆盖插件目录为旧版即可。书架、进度、缓存、设备池文件保留在数据目录，不受影响。

## 7. 数据文件位置速查

| 文件 | 位置 |
|------|------|
| 插件本体 + config.lua | `<KOReader>/plugins/fanqie.koplugin/` |
| 设备池 | `<数据目录>/fanqie/app_device_pool.txt` |
| 书源/账号设置 | `<数据目录>/settings/fanqie.lua` |
| 章节缓存 | `<数据目录>/fanqie/cache/<book_id>/` |

`<数据目录>` = `settings.reader.lua` 所在目录（Kindle: `/mnt/us/koreader`，Kobo: `/mnt/onboard/.adds/koreader`）。找不到时可直接按文件名搜索确认。
