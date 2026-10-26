-- fanqie/menus/menu_actions.lua —— 从 main.lua 按原函数边界拆分。
-- 方法名与实现保持原接口；共享依赖集中在 fanqie.runtime。

local function safe_require(name)
    local ok, module = pcall(require, name)
    if not ok then return nil end
    return module
end

local lfs = safe_require("libs/libkoreader-lfs")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template
local Device = require("device")
local Screen = Device.screen
local Runtime = require("fanqie.runtime")
local _state = Runtime.state
local M = {}

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local DataStorage = require("datastorage")
local TextViewer = require("ui/widget/textviewer")
local FanQie = require("fanqie.fanqie")
local H = require("fanqie.helper")
local Log = require("fanqie.logger")
local Async = require("fanqie.async")
local CoverCache = require("fanqie.cover_cache")
local UpdaterUI = safe_require("fanqie.updater_ui")
local Info = safe_require("fanqie.info")
local Startup = safe_require("fanqie.startup")

function M:getMainMenuItems()
    local items = {
        {
            text = _("书架"),
            callback = self:safeCallback(_("书架"), function()
                self:showBookshelf()
            end),
        },
        {
            text = _("书城"),
            callback = self:safeCallback(_("书城"), function()
                self:showStore()
            end),
        },
        {
            text = _("搜索书籍"),
            callback = self:safeCallback(_("搜索书籍"), function()
                self:showAppSearchDialog()
            end),
        },
        {
            text = _("发现书籍"),
            sub_item_table_func = function()
                return self:getAppExploreMenuItems()
            end,
        },
        {
            text = _("下载管理"),
            callback = self:safeCallback(_("下载管理"), function()
                self:showDownloadManager()
            end),
        },
        {
            text = _("设置"),
            sub_item_table_func = function()
                return self:getSettingsMenuItems()
            end,
        },
        {
            text = _("缓存管理"),
            sub_item_table_func = function()
                -- 🔴 兜底闸门：这个子菜单要读文件系统（缓存目录遍历 / 占用统计 /
                --    段评图片目录），任何一项抛错都会让 `Menu` 构建失败 ——
                --    在设备上表现为「点开缓存管理就闪退」，且没有任何可读提示。
                --    这里把异常降级成一行可读文案 + fanqie.log 里一条 WARN。
                local ok, items = pcall(self.getCacheMenuItems, self)
                if ok and type(items) == "table" then return items end
                if Log then Log.warn("[缓存管理] 菜单构建失败: " .. tostring(items)) end
                local msg = tostring(items):match("^[^\n]*") or ""
                if #msg > 120 then msg = msg:sub(1, 120) end
                return {
                    {
                        text = T(_("缓存管理加载失败：%1"), msg),
                        enabled = false,
                    },
                }
            end,
        },
        {
            text = _("在线更新"),
            sub_item_table_func = function()
                return self:getUpdateMenuItems()
            end,
        },
    }
    
    -- Add "Reload current chapter" option only when reading a fanqie chapter
    if self:isCurrentDocFanqie() and _state.current_chapter_index and _state.current_chapter_index > 0 then
        table.insert(items, {
            text = _("重新获取本章节"),
            separator = true,
            callback = self:safeCallback(_("重新获取本章节"), function()
                self:reloadCurrentChapter()
            end),
        })
    end
    
    table.insert(items, {
        text = _("关于"),
        callback = self:safeCallback(_("关于"), function()
            -- cover_cell 的构建标记：用户报「网格改动没生效」时，先看这行 ——
            -- 标记是旧的 ⇒ 设备上那份 cover_cell.lua 没换上（解压/覆盖问题），
            -- 不是代码没改。
            local ok_cc, CCm = pcall(require, "fanqie.cover_cell")
            local build_note = (ok_cc and CCm and CCm.BUILD)
                and T(_("（cover_cell 构建 %1）"), CCm.BUILD) or ""
            UIManager:show(InfoMessage:new{
                text = T(Info and Info.about_template or _("番茄小说插件 v%1"), self.version, self.settings:get_download_dir())
                    .. build_note,
            })
        end),
    })
    
    return items
end

-- 在线更新菜单（实现见 fanqie/updater_ui.lua）
function M:getUpdateMenuItems()
    if not (UpdaterUI and UpdaterUI.menu_items) then
        return {
            { text = _("当前环境不支持在线更新（网络组件不可用）"), enabled = false },
        }
    end
    return UpdaterUI.menu_items(self)
end

-- ===========================================================================
-- Settings menu
-- ===========================================================================

--- 「阅读中定期上传进度」档位（分钟）。0 = 关闭。
-- 默认见 `fanqie/settings.lua` 的 `sync.upload_interval_minutes`。
M.PROGRESS_UPLOAD_PRESETS = { 0, 1, 3, 5, 10 }

--- 设置 → 阅读中定期上传进度：单选档位。
--
-- 存在的理由：以前进度只在「末页翻章 / 关文档 / 开目录」三个时刻上传，
-- 读到一半退出（关 KOReader、切书、掉电、被杀）这段进度就没了 ——
-- README 里承诺的「阅读中定期上传」在那之前其实并不存在。
--- 「阅读中定期上传进度」档位（分钟）。0 = 关闭。
M.PROGRESS_UPLOAD_PRESETS = { 0, 1, 3, 5, 10 }

function M:getProgressUploadIntervalItems()
    local function current_minutes()
        local ok, sync = pcall(function() return self.settings:get("sync", {}) end)
        if not ok or type(sync) ~= "table" then return 0 end
        return tonumber(sync.upload_interval_minutes) or 0
    end

    local items = {}
    for _i, minutes in ipairs(M.PROGRESS_UPLOAD_PRESETS) do
        local value = minutes
        items[#items + 1] = {
            text = value <= 0 and _("关闭") or T(_("每 %1 分钟"), tostring(value)),
            radio = true,
            checked_func = function() return current_minutes() == value end,
            keep_menu_open = true,
            callback = function()
                local sync = self.settings:get("sync", {}) or {}
                sync.upload_interval_minutes = value
                self.settings:set("sync", sync)
                self.settings:flush()
                -- 立刻生效：先停掉旧链，需要的话再挂新的
                self:_stopProgressTimer()
                if value > 0 then
                    self:_ensureProgressTimer()
                end
            end,
        }
    end
    return items
end

--- 设置 → 封面缓存：有效期 + 占用 + 清理。
function M:getCoverCacheMenuItems()
    local dirs = self:_coverCacheDirs()

    -- 「共 N 张 · X MB」：两个目录合起来算（书架的 covers/ 与书城的 store_covers/）
    local function total_stats()
        local files, bytes = 0, 0
        if CoverCache then
            for _i, d in ipairs(dirs) do
                local st = CoverCache.stats(d)
                files = files + (st.files or 0)
                bytes = bytes + (st.bytes or 0)
            end
        end
        return files, bytes
    end

    local function run(action)
        local removed, freed = 0, 0
        if CoverCache then
            for _i, d in ipairs(dirs) do
                local r = action(d)
                removed = removed + (r.removed or 0)
                freed = freed + (r.bytes or 0)
            end
        end
        return removed, freed
    end

    local items = {}
    items[#items + 1] = {
        text = _("缓存有效期"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local out = {}
            for _i, days in ipairs(CoverCache and CoverCache.DAYS_PRESETS or { 3, 7, 9, 30, 0 }) do
                out[#out + 1] = {
                    text = CoverCache and CoverCache.days_label(days) or tostring(days),
                    checked_func = function()
                        return self.settings:get_cover_cache_days() == days
                    end,
                    keep_menu_open = true,
                    callback = function()
                        self.settings:set_cover_cache_days(days)
                        self:showInfo(T(_("封面缓存有效期已设为 %1"), tostring(days > 0 and (days .. " 天") or _("永久"))))
                    end,
                }
            end
            return out
        end,
    }
    items[#items + 1] = {
        text_func = function()
            local files, bytes = total_stats()
            return T(_("清理过期封面（共 %1 张 · %2）"), tostring(files),
                CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local removed, freed = run(function(d)
                return CoverCache and CoverCache.prune(d, self.settings:get_cover_cache_days())
                    or { removed = 0, bytes = 0 }
            end)
            self:showInfo(T(_("已清理 %1 张，释放 %2"), tostring(removed),
                CoverCache and CoverCache.human_bytes(freed) or tostring(freed)))
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }
    items[#items + 1] = {
        text_func = function()
            local files, bytes = total_stats()
            return T(_("清空封面缓存（%1 张 · %2）"), tostring(files),
                CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local files, bytes = total_stats()
            if files == 0 then
                self:showInfo(_("封面缓存是空的"))
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("删除全部封面缓存？共 %1 张（%2）。\n下次打开书架/书城时会重新下载。"),
                    tostring(files), CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes)),
                ok_text = _("删除"),
                ok_callback = function()
                    local removed, freed = run(function(d)
                        return CoverCache and CoverCache.clear(d) or { removed = 0, bytes = 0 }
                    end)
                    self:showInfo(T(_("已清空 %1 张，释放 %2"), tostring(removed),
                        CoverCache and CoverCache.human_bytes(freed) or tostring(freed)))
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
    return items
end

function M:getSettingsMenuItems()
    return {
        {
            text = _("初始页面"),
            keep_menu_open = true,
            sub_item_table = {
                {
                    text = _("文件管理器"),
                    keep_menu_open = true,
                    checked_func = function()
                        return self.settings:getStartupPage() == "filemanager"
                    end,
                    callback = function()
                        self:setStartupPage("filemanager")
                    end,
                },
                {
                    text = _("番茄书架"),
                    keep_menu_open = true,
                    checked_func = function()
                        return self.settings:getStartupPage() == "bookshelf"
                    end,
                    callback = function()
                        self:setStartupPage("bookshelf")
                    end,
                },
            },
        },
        {
            -- 「读完直接回书架」：关闭阅读器后自动打开番茄书架，
            -- 不用再经过文件管理器。默认开启 —— 这是读番茄书最顺的循环：
            -- 点书 → 读 → 关闭 → 下一本。
            text = _("关闭阅读后回书架"),
            checked_func = function()
                return self.settings:get("return_to_shelf_on_close", true) ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local cur = self.settings:get("return_to_shelf_on_close", true) ~= false
                self.settings:set("return_to_shelf_on_close", not cur)
                self.settings:flush()
            end,
        },
        {
            text = _("缓存目录"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showDownloadDirPicker(touchmenu_instance)
            end,
        },
        {
            text_func = function()
                -- 统一走 H.prefetch_count（唯一读取口径），不再各处写死 `or 3`
                local count = H.prefetch_count(self.settings)
                if count <= 0 then
                    return _("预下载: 已关闭")
                end
                return T(_("预下载章节数: %1"), tostring(count))
            end,
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getPreDownloadMenuItems()
            end,
        },
        
        {
            text = _("下载图片"),
            checked_func = function()
                local cache = self.settings:get("cache")
                return cache.download_book_images ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local cache = self.settings:get("cache")
                local value = not (cache.download_book_images ~= false)
                -- 走 set_cache_pref：标记「用户显式设置」，config.lua 不覆盖
                if self.settings.set_cache_pref then
                    self.settings:set_cache_pref("download_book_images", value)
                else
                    cache.download_book_images = value
                    self.settings:set("cache", cache)
                    self.settings:flush()
                end
            end,
        },
        {
            text = _("封面缓存"),
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getCoverCacheMenuItems()
            end,
        },
        {
            text = _("段评显示"),
            checked_func = function()
                return _state.isReviewEnabled()
            end,
            keep_menu_open = true,
            callback = function()
                _state.setReviewEnabled(not _state.isReviewEnabled())
            end,
        },
        {
            -- v2.16.24：段评数字是上标小字，单独点不好点 ⇒ 有段评的段落整段可点
            -- （段落带下划线提示）。关掉后只认那个数字。
            text = _("段评整段可点"),
            checked_func = function()
                return self.settings:getParaTapWhole() ~= false
            end,
            keep_menu_open = true,
            callback = function()
                self.settings:setParaTapWhole(not (self.settings:getParaTapWhole() ~= false))
                -- 已有缓存章节在打开时会自动按新开关升级/回退吗？不会 —— 升级只做
                -- 「补齐」，不删已有的整段锚点。所以这里提示一句，避免用户以为没生效。
                self:showInfo(_("已保存。新打开（或重新下载）的章节生效。"), 2)
            end,
        },
        {
            text = _("读取进度同步"),
            checked_func = function()
                local sync = self.settings:get("sync", {})
                return sync.pull_on_open ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local sync = self.settings:get("sync", {})
                sync.pull_on_open = not (sync.pull_on_open ~= false)
                self.settings:set("sync", sync)
                self.settings:flush()
            end,
        },
        {
            text = _("Upload progress on close"),
            help_text = _("离开阅读界面时把最后一次进度补传上去"),
            checked_func = function()
                return self:_uploadOnCloseEnabled()
            end,
            keep_menu_open = true,
            callback = function()
                local sync = self.settings:get("sync", {}) or {}
                sync.upload_on_close = not (sync.upload_on_close ~= false)
                self.settings:set("sync", sync)
                self.settings:flush()
            end,
        },
        {
            text = _("阅读中定期上传进度"),
            help_text = _("读到一半退出 / 掉电也不会丢进度（读到哪传到哪）"),
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getProgressUploadIntervalItems()
            end,
        },
        {
            text = _("重新加载配置文件"),
            keep_menu_open = true,
            callback = function()
                self:loadConfigFile(false, true, true)
            end,
        },
        {
            text = _("扫码登录"),
            keep_menu_open = false,
            callback = function()
                local QRLogin = require("fanqie.qrlogin")
                local qr = QRLogin:new(self.client, self.settings, self)
                qr:start()
            end,
        },
        {
            text = _("退出登录"),
            -- 🔴 字段名必须是 Menu 认的那个：KOReader `Menu:onMenuSelect` 只检查
            --    `item.select_enabled == false` 和 `item.select_enabled_func`，
            --    写 `enabled_func` 等于**没写**（条目照旧可点）。
            select_enabled_func = function()
                return self.settings:is_cookie_configured()
            end,
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("确定退出登录？将清除已保存的 Cookie。"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        self.settings:set("cookies", {})
                        self.settings:flush()
                        self:showInfo(_("已退出登录"))
                    end,
                })
            end,
        },
        {
            text = _("书源管理"),
            sub_item_table_func = function()
                return self:getSourceMenuItems()
            end,
        },
        {
            text = _("调试日志"),
            sub_item_table_func = function()
                return self:getLogMenuItems()
            end,
        },
    }
end

-- 切换初始页面（KOReader 启动页）：持久化到插件设置，
-- 并同步 KOReader 内置 start_with 设置，让启动分支与初始页面保持一致。
-- 改动在下一次 KOReader 冷启动时生效。
function M:setStartupPage(page)
    if not self.settings:setStartupPage(page) then return end
    if Startup and Startup.syncKoreaderStartWith then
        pcall(function() Startup.syncKoreaderStartWith(self.settings) end)
    end
    self:showInfo(_("初始页面已更新，重启 KOReader 后生效"))
end

-- ===========================================================================
-- 书源管理（内置番茄APP / 官方API）
-- ===========================================================================

function M:getSourceMenuItems()
    local SourceManager = require("fanqie.sources")
    local ordered = SourceManager.get_all_sources(self.settings)
    local items = {}
    for _i, src in ipairs(ordered) do
        local cfg = src.config
        local meta = src.meta
        local is_dev = meta.in_development == true
        local is_enabled = cfg.enabled ~= false
        local is_configured = SourceManager.is_configured(src.id, cfg, self.settings)
        local name = meta.name
        if is_dev then name = name .. _(" (开发中)") end
        if not is_configured and not is_dev then name = name .. _(" (未配置)") end
        local display_name = name
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source(src.id)
                local prefix = (c.enabled ~= false) and "●" or "○"
                return string.format("%s %s", prefix, display_name)
            end,
            enabled_func = function() return not is_dev end,
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getSourceDetailMenuItems(src.id)
            end,
        })
    end
    return items
end

function M:getSourceDetailMenuItems(source_id)
    local SourceManager = require("fanqie.sources")
    local meta = SourceManager.REGISTRY[source_id]
    local items = {}

    -- Enable / disable toggle (dev sources lock this)
    if not meta.in_development then
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source(source_id)
                return c.enabled ~= false and _("禁用此源") or _("启用此源")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local c = self.settings:get_source(source_id)
                self.settings:set_source_field(source_id, "enabled", c.enabled == false)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        })
    end

    -- 番茄APP内置源：设备池状态 / 注册新设备 / 清空设备
    if source_id == "fanqie_app" then
        table.insert(items, {
            text_func = function()
                local st = self.client:fanqie_app_device_status()
                if st.count > 0 then
                    return string.format(_("设备池: %d 台 (%s...)"), st.count, tostring(st.first):sub(1, 6))
                end
                return _("设备池: 空 (首次使用时自动注册)")
            end,
            keep_menu_open = true,
            callback = function() end,
        })
        table.insert(items, {
            text = _("注册新设备"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showBusy(_("正在注册设备..."))
                local client = self.client
                Async.run(function()
                    return client:fanqie_app_register_device()
                end, function(ok, result, err)
                    self:closeBusy()
                    if ok and result then
                        UIManager:show(InfoMessage:new{ text = _("设备注册成功"), timeout = 2 })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("设备注册失败: ") .. tostring(err or result), timeout = 3,
                        })
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end, { delay = 0.1, poll_interval = 0.2, timeout = 30 })
            end,
        })
        table.insert(items, {
            text = _("清空设备池"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new{
                    text = _("确定清空设备池？\n下次使用时将自动重新注册设备。"),
                    ok_text = _("清空"),
                    cancel_text = _("取消"),
                    ok_callback = function()
                        self.client:fanqie_app_clear_devices()
                        local SM = require("fanqie.sources")
                        SM.rate_limit_reset("fanqie_app")
                        UIManager:show(InfoMessage:new{ text = _("设备池已清空"), timeout = 2 })
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        })
    end

    -- Rate limit setting (all sources)
    -- separator=true：在该项下方画横线，把"上移/下移"整组与上方配置项视觉分隔
    table.insert(items, {
        text_func = function()
            local c = self.settings:get_source(source_id)
            local rl = c.rate_limit or {}
            local mr = rl.max_requests or 0
            local ws = (rl.window_seconds or 0) > 0 and rl.window_seconds or 30
            if mr == 0 then
                return _("限流: 无限制")
            end
            return string.format(_("限流: %d次 / %ds"), mr, ws)
        end,
        separator = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showSourceRateLimitDialog(source_id, touchmenu_instance)
        end,
    })

    -- Move up / down
    -- 修复返回书源列表顺序不刷新的 bug：KOReader TouchMenu 返回父页时默认用栈中缓存的
    -- 旧 item_table，不会重新调用 sub_item_table_func。这里给父页（书源列表）挂
    -- needs_refresh + refresh_func，再 backToUpperMenu 返回时即触发重建，立即看到新顺序。
    local function move_and_refresh(direction)
        return function(touchmenu_instance)
            self.settings:move_source(source_id, direction)
            if touchmenu_instance and touchmenu_instance.item_table_stack then
                local parent = touchmenu_instance.item_table_stack[#touchmenu_instance.item_table_stack]
                if parent then
                    parent.needs_refresh = true
                    parent.refresh_func = function()
                        return self:getSourceMenuItems()
                    end
                end
            end
            -- 返回书源列表，触发 needs_refresh → refresh_func 重建列表（新顺序立即生效）
            if touchmenu_instance and touchmenu_instance.backToUpperMenu then
                touchmenu_instance:backToUpperMenu()
            end
        end
    end

    table.insert(items, {
        text = _("上移"),
        separator = true,
        keep_menu_open = true,
        callback = move_and_refresh(-1),
    })
    table.insert(items, {
        text = _("下移"),
        keep_menu_open = true,
        callback = move_and_refresh(1),
    })

    return items
end


function M:showSourceRateLimitDialog(source_id, touchmenu_instance)
    if not InputDialog then
        self:showInfo(_("系统不支持输入对话框"))
        return
    end
    local cfg = self.settings:get_source(source_id)
    local rl = cfg.rate_limit or { max_requests = 0, window_seconds = 0 }
    local dialog
    dialog = InputDialog:new{
        title = _("限流设置"),
        input = tostring(rl.max_requests or 0),
        input_type = "number",
        description = _("格式: 最大请求数 / 时间窗口(秒)，0=无限制\n示例: 5/30 表示 30秒内最多5次"),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local input = dialog:getInputText() or ""
                        UIManager:close(dialog)
                        local mr_str, win_str = input:match("^(%d+)%s*/%s*(%d+)$")
                        if not mr_str then
                            mr_str = input:match("^(%d+)$")
                            win_str = tostring(rl.window_seconds or 30)
                        end
                        if not mr_str then
                            self:showInfo(_("格式错误"))
                            return
                        end
                        local mr = tonumber(mr_str) or 0
                        local win = (tonumber(win_str) or 30)
                        if win <= 0 then win = 30 end
                        if mr < 0 then
                            self:showInfo(_("数值不能为负"))
                            return
                        end
                        local new_cfg = self.settings:get_source(source_id)
                        new_cfg.rate_limit = { max_requests = mr, window_seconds = win }
                        self.settings:set_source(source_id, new_cfg)
                        -- Reset this source's rate-limit state so the new config
                        -- takes effect immediately (old timestamps cleared).
                        local SM = require("fanqie.sources")
                        SM.rate_limit_reset(source_id)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                        UIManager:show(InfoMessage:new{
                            text = _("限流设置已保存"), timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M:getLogMenuItems()
    return {
        {
            text_func = function()
                local advanced = self.settings:get("advanced", {})
                return advanced.developer_logs and _("调试日志: 开") or _("调试日志: 关")
            end,
            checked_func = function()
                local advanced = self.settings:get("advanced", {})
                return advanced.developer_logs == true
            end,
            keep_menu_open = true,
            callback = function()
                local advanced = self.settings:get("advanced", {})
                advanced.developer_logs = not (advanced.developer_logs == true)
                self.settings:set("advanced", advanced)
                self.settings:flush()
                if advanced.developer_logs then
                    Log.info("debug logging enabled")
                end
            end,
        },
        {
            text = _("查看日志文件"),
            keep_menu_open = true,
            callback = function()
                local log_path = Log.get_log_file_path()
                if not log_path then
                    self:showInfo(_("日志文件路径未初始化"))
                    return
                end
                if not lfs or not lfs.attributes(log_path, "mode") then
                    self:showInfo(_("日志文件不存在，开启调试日志后操作插件即可生成"))
                    return
                end
                -- Copy log to a temp location for safe viewing
                local tmp_dir = DataStorage:getDataDir() .. "/tmp"
                H.make_dir(tmp_dir)
                local tmp_path = tmp_dir .. "/fanqie_log_viewer.txt"
                local src = io.open(log_path, "r")
                if not src then
                    self:showInfo(_("无法读取日志文件"))
                    return
                end
                local content = src:read("*a")
                src:close()
                if #content > 20000 then
                    content = content:sub(-20000)
                end
                local dst = io.open(tmp_path, "w")
                if not dst then
                    self:showInfo(_("无法写入临时文件"))
                    return
                end
                dst:write(content)
                dst:close()
                -- 直接用文本查看器打开。
                -- 此前这里先构造了一个 `local fm = FileManager:new{...}`，但 fm 之后再无
                -- 任何引用（下面注释自己都写了 "Simpler approach: show in text viewer"），
                -- 且 dimen 用了一个并不存在的 API（Screen:getDeviceScreenSize），
                -- 属死代码 + 崩溃地雷，故整块移除，只保留真正生效的分支。
                local TextViewer = safe_require("ui/widget/textviewer")
                if TextViewer then
                    UIManager:show(TextViewer:new{
                        title = _("FanQie 插件日志"),
                        text = content,
                    })
                else
                    -- ⚠️ 必须是 T（util.template）而不是 _：`_(fmt, arg)` 里
                    --    gettext 会把第二个参数整个丢掉，用户看到的是字面 `%1`。
                    self:showInfo(T(_("日志已复制到: %1"), tmp_path))
                end
            end,
        },
        {
            text = _("清除日志"),
            keep_menu_open = true,
            callback = function()
                Log.clear_log()
                self:showInfo(_("日志已清除"))
            end,
        },
        {
            text = _("在文件管理器中查看"),
            keep_menu_open = true,
            callback = function()
                local log_path = Log.get_log_file_path()
                if not log_path then return end
                local dir = log_path:match("^(.*)/[^/]+$") or self.settings:get_download_dir()
                local FileManager = require("apps/filemanager/filemanager")
                local RUI = require("apps/reader/readerui")
                if RUI and RUI.instance then
                    RUI.instance:onClose()
                    UIManager:scheduleIn(0.1, function()
                        FileManager:showFiles(dir)
                    end)
                else
                    FileManager:showFiles(dir)
                end
            end,
        },
    }
end

-- 预下载章节数选项（0 = 关闭预下载）。
-- 集中在此维护，避免像旧实现那样在 4 个 checked_func + 读取点各写一份 `or 3`：
-- 那种重复一旦某处不同步，用户就会看到「改了没用，一直默认 3」。
function M:getPreDownloadMenuItems()
    local choices = {
        { value = 0,  text = _("关闭") },
        { value = 1,  text = "1" },
        { value = 3,  text = "3" },
        { value = 5,  text = "5" },
        { value = 10, text = "10" },
        { value = 20, text = "20" },
    }
    local items = {}
    for _, c in ipairs(choices) do
        local value = c.value
        table.insert(items, {
            text = c.text,
            keep_menu_open = true,
            callback = function() self:setPreDownloadCount(value) end,
            checked_func = function()
                local count = H.prefetch_count(self.settings)
                return count == value
            end,
        })
    end
    return items
end

function M:setPreDownloadCount(n)
    n = math.floor(tonumber(n) or 3)
    if n < 0 then n = 0 end
    -- 走 set_cache_pref：写值 + 标记「用户显式设置」，
    -- 使 config.lua 的同名值不再覆盖菜单里的选择（优先级：菜单 > config > 默认）。
    if self.settings.set_cache_pref then
        self.settings:set_cache_pref("pre_download_chapters", n)
    else
        local cache = self.settings:get("cache")
        cache.pre_download_chapters = n
        self.settings:set("cache", cache)
        self.settings:flush()
    end
    if Log then Log.info("[FanQie] pre_download_chapters =", n) end
end

function M:showDownloadDirPicker(touchmenu_instance)
    local path_chooser = PathChooser:new{
        select_file = false,
        path = self.settings:get_download_dir(),
        onConfirm = function(path)
            self.settings:set_download_dir(path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            UIManager:show(InfoMessage:new{
                text = T(_("缓存目录已设置为:\n%1"), path),
                timeout = 2,
            })
        end,
    }
    UIManager:show(path_chooser)
end

-- ===========================================================================
-- Config file loading
-- ===========================================================================

function M:loadConfigFile(silent, force, override)
    local plugin_path = self:getPluginPath()
    local config_path = plugin_path .. "/config.lua"

    -- 🔴 三种失败都要**出声**（除非是启动时的静默加载）：
    --    菜单里点「重新加载配置文件」以前遇到「文件不存在」/「语法错」直接
    --    return，用户看到的是「点了完全没反应」，没法判断是没配置成功还是插件挂了
    --    （实测 2026-10-20：设备插件目录里根本没有 config.lua）。
    local function notify(text)
        if silent then return end
        UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
    end

    local file = io.open(config_path, "r")
    if not file then
        notify(_("未找到 config.lua。\nCookie 与登录状态保存在设置里（扫码登录即可），config.lua 是可选的。"))
        return
    end
    file:close()

    local ok, config = pcall(dofile, config_path)
    if not ok then
        notify(T(_("config.lua 解析失败：\n%1"), tostring(config)))
        return
    end
    if type(config) ~= "table" then
        notify(_("config.lua 的内容必须是一个 table（return { ... }）。"))
        return
    end
    
    pcall(function()
        -- override：显式重载时以 config.lua 为准（含清掉菜单的显式设置标记）。
        -- 启动时的静默加载 override=false，绝不冲掉用户在菜单里的选择。
        self.settings:apply_config(config, {
            apply_preferences = true,
            force = force,
            override_existing = override or false,
        })
    end)
    
    if not silent then
        -- 补入缺失 cookie 时如实报出来：书城搜索只认风控标识 s_v_web_id，而扫码登录
        -- 拿不到它（实测不下发）⇒「把浏览器 Cookie 填进 config.lua」是**唯一**能让
        -- 搜索恢复的路径，用户必须看得见它到底生效了没有。
        local sup = self.settings.cookie_supplemented
        local text = _("config.lua loaded.")
        if type(sup) == "table" and #sup > 0 then
            text = T(_("config.lua loaded.\n已补入本地缺失的 Cookie: %1"),
                table.concat(sup, ", "))
        end
        UIManager:show(InfoMessage:new{
            text = text, timeout = 2,
        })
    end
end

function M:getPluginPath()
    return Runtime.plugin_path
end

-- ===========================================================================
-- Network check
-- ===========================================================================

function M:checkNetwork()
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        self:showInfo(_("未连接网络，请先开启 WiFi"))
        return false
    end
    return true
end



--- 两处封面缓存目录（书架与书城均优先按 book_id）。清理由此统一入口。
function M:_coverCacheDirs()
    local base = self.settings:get_download_dir()
    return { base .. "/covers", base .. "/store_covers" }
end

--- 「清空书架缓存」的占用统计：shelf_cache.lua（书单文件）+ covers/（书架封面）。
-- 榜单/章节缓存在别处算，这里只算「书架身份」的两块。
function M:_shelfCacheBytes()
    local bytes = 0
    local base = self.settings:get_download_dir()
    local shelf_file = base .. "/shelf_cache.lua"
    if lfs and H.file_exists(shelf_file) then
        bytes = bytes + (tonumber(lfs.attributes(shelf_file, "size")) or 0)
    end
    if CoverCache then
        local st = CoverCache.stats(base .. "/covers")
        bytes = bytes + (tonumber(st and st.bytes) or 0)
    end
    return bytes
end

--- 「清空书城缓存」的占用统计：store_covers/（书城封面）。
-- 榜单短缓存在内存里（`_store_rank_cache`），不计字节，但清空时一并删。
function M:_storeCacheBytes()
    if not CoverCache then return 0 end
    local st = CoverCache.stats(self.settings:get_download_dir() .. "/store_covers")
    return tonumber(st and st.bytes) or 0
end

--- 「清空评论缓存」的占用统计：comment_images/（段评图片）。
-- 段评数据本身在内存里（`_para_pages`，换书/换章即失效），落盘的只有图片。
function M:_commentCacheBytes()
    if not CoverCache then return 0 end
    local st = CoverCache.stats(self:_comment_image_dir())
    return tonumber(st and st.bytes) or 0
end

--- 这张封面缓存还能用吗：**存在**且**没过有效期**。
--- ⚠️ 只判 `file_exists` 的话封面一旦落盘就永不失效（书城活动换图后一直显示旧图，
---    而且只增不减）。有效期见 settings 的 `cache.cover_cache_days`（0 = 永久）。
function M:_coverCacheUsable(path)
    if not (H and H.file_exists(path)) then return false end
    if not CoverCache then return true end
    local days = self.settings.get_cover_cache_days and self.settings:get_cover_cache_days()
    return CoverCache.is_fresh(path, days)
end


return M
