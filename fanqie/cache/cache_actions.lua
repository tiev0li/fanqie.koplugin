-- fanqie/cache/cache_actions.lua —— 从 main.lua 按原函数边界拆分。
-- 方法名与实现保持原接口；共享依赖集中在 fanqie.runtime。

local function safe_require(name)
    local ok, module = pcall(require, name)
    if not ok then return nil end
    return module
end

local lfs = require("libs/libkoreader-lfs")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template
local Device = require("device")
local Screen = Device.screen
local Runtime = require("fanqie.runtime")
local _state = Runtime.state

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Menu = require("ui/widget/menu")
local Log = require("fanqie.logger")
local CoverCache = require("fanqie.cover_cache")
local Async = safe_require("fanqie.async")

local M = {}

function M:getCacheMenuItems()
    local items = {}
    -- 🔴 统计**绝不能**把整个菜单拖崩：`Settings:get_cache_stats()` 会双层遍历
    --    缓存目录（145 本书 × 每章一个 html），任何一次 `lfs.dir` 失败
    --    （目录删到一半 / 权限 / 坏项 / 中途被别的进程动过）都会抛错，
    --    而它是本菜单的**第一行** ⇒ 整个子菜单构建失败 = 用户看到的
    --    「缓存管理一打开就闪退」。降级成零值，菜单照常可用。
    local ok_stats, stats = pcall(function() return self.settings:get_cache_stats() end)
    if not ok_stats or type(stats) ~= "table" then
        if Log then Log.warn("[缓存管理] get_cache_stats 失败，降级为零统计: " .. tostring(stats)) end
        stats = { book_count = 0, chapter_count = 0, total_size = 0, degraded = tostring(stats) }
    end
    local book_count = tonumber(stats.book_count) or 0
    local chapter_count = tonumber(stats.chapter_count) or 0
    local total_size = tonumber(stats.total_size) or 0
    local size_mb = total_size / (1024 * 1024)

    -- text_func 求值失败同样会让菜单构建抛错（闪退）⇒ 统一兜底成一行可读文案，
    -- 并把真实原因写进 fanqie.log（设备侧唯一的可诊断线索）。
    local function safe_label(fn)
        local function render()
            local ok, text = pcall(fn)
            if ok and type(text) == "string" then return text end
            if Log then Log.warn("[缓存管理] 占用文案求值失败: " .. tostring(text)) end
            return _("（读取占用失败）")
        end
        return render
    end

    table.insert(items, {
        text = stats.degraded
            and _("缓存统计: 暂不可用（读取缓存目录失败）")
            or string.format(_("缓存统计: %d 本书, %d 章节, %.1f MB"), book_count, chapter_count, size_mb),
        -- 纯展示行（见下方 Menu 的字段名说明）：Menu 只认 select_enabled/select_enabled_func
        select_enabled = false,
    })
    table.insert(items, {
        text = _("查看缓存目录"),
        keep_menu_open = true,
        callback = function()
            local dir = self.settings:get_download_dir()
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
    })
    table.insert(items, {
        text = _("刷新章节缓存"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("确定刷新章节缓存?\n下次打开书籍时将重新获取最新章节列表。"),
                ok_text = _("刷新"),
                cancel_text = _("取消"),
                ok_callback = function()
                    _state.invalidateAllCache()
                    self:clearShelfCache()
                    UIManager:show(InfoMessage:new{
                        text = _("章节缓存已刷新"),
                    })
                end,
            })
        end,
    })
    -- 书架缓存 = 书单缓存（shelf_cache.lua 三层 + 快照）+ 书架封面（covers/）。
    -- 书城缓存 = 榜单短缓存（内存）+ 书城封面（store_covers/）。
    -- 两者拆开是因为目录本来就分开（covers/ vs store_covers/），用户经常只想清一边。
    table.insert(items, {
        text_func = safe_label(function()
            local bytes = self:_shelfCacheBytes()
            return T(_("清空书架缓存（书单 + 封面 · %1）"),
                CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes))
        end),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local bytes = self:_shelfCacheBytes()
            if bytes <= 0 then
                self:showInfo(_("书架缓存是空的"))
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("删除书架缓存（书单缓存 + 书架封面，共 %1）？\n书架列表下次打开会重新联网获取，封面会重新下载。"),
                    CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes)),
                ok_text = _("清空"),
                cancel_text = _("取消"),
                ok_callback = function()
                    -- 书单三层（显示层内存 / client API 短缓存 / shelf_cache.lua）+ 快照
                    self:clearShelfCache()
                    local removed = 0
                    if CoverCache then
                        local r = CoverCache.clear(self.settings:get_download_dir() .. "/covers")
                        removed = r.removed or 0
                    end
                    self:showInfo(T(_("书架缓存已清空（含封面 %1 张）"), tostring(removed)))
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    })
    table.insert(items, {
        text_func = safe_label(function()
            local bytes = self:_storeCacheBytes()
            return T(_("清空书城缓存（榜单 + 封面 · %1）"),
                CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes))
        end),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local bytes = self:_storeCacheBytes()
            local has_rank = type(self._store_rank_cache) == "table" and next(self._store_rank_cache) ~= nil
            if bytes <= 0 and not has_rank then
                self:showInfo(_("书城缓存是空的"))
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("删除书城缓存（榜单缓存 + 书城封面，共 %1）？\n榜单下次打开会重新联网获取，封面会重新下载。"),
                    CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes)),
                ok_text = _("清空"),
                cancel_text = _("取消"),
                ok_callback = function()
                    self._store_rank_cache = nil
                    local removed = 0
                    if CoverCache then
                        local r = CoverCache.clear(self.settings:get_download_dir() .. "/store_covers")
                        removed = r.removed or 0
                    end
                    self:showInfo(T(_("书城缓存已清空（含封面 %1 张）"), tostring(removed)))
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    })
    -- 评论缓存 = 段评图片（comment_images/）。段评数据在内存里（换书/换章失效），
    -- 落盘的只有图片；有效期档位也放在这条旁边，用户不用去设置里翻。
    table.insert(items, {
        text_func = safe_label(function()
            local files, bytes = 0, 0
            if CoverCache then
                local st = CoverCache.stats(self:_comment_image_dir())
                files = st.files or 0
                bytes = st.bytes or 0
            end
            return T(_("清空评论缓存（段评图片 · %1 张 · %2）"), tostring(files),
                CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes))
        end),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local files, bytes = 0, 0
            if CoverCache then
                local st = CoverCache.stats(self:_comment_image_dir())
                files = st.files or 0
                bytes = st.bytes or 0
            end
            if files <= 0 then
                self:showInfo(_("评论缓存是空的"))
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("删除全部段评图片缓存？共 %1 张（%2）。\n下次打开段评时会按需重新下载。"),
                    tostring(files), CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes)),
                ok_text = _("清空"),
                cancel_text = _("取消"),
                ok_callback = function()
                    -- 段评图片落盘 + 段评页缓存（内存）一起清
                    local removed = 0
                    if CoverCache then
                        local r = CoverCache.clear(self:_comment_image_dir())
                        removed = r.removed or 0
                    end
                    self._para_pages = nil
                    self:showInfo(T(_("评论缓存已清空（%1 张）"), tostring(removed)))
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    })
    table.insert(items, {
        text = _("评论图片有效期"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local out = {}
            for _i, mins in ipairs(CoverCache and CoverCache.COMMENT_TTL_PRESETS or { 10, 30, 60, 180, 0 }) do
                out[#out + 1] = {
                    text = CoverCache and CoverCache.minutes_label(mins) or tostring(mins),
                    checked_func = function()
                        return self.settings.get_comment_image_ttl_minutes
                            and self.settings:get_comment_image_ttl_minutes() == mins
                    end,
                    keep_menu_open = true,
                    callback = function()
                        self.settings:set_comment_image_ttl_minutes(mins)
                        self:showInfo(T(_("评论图片有效期已设为 %1"),
                            CoverCache and CoverCache.minutes_label(mins) or tostring(mins)))
                    end,
                }
            end
            return out
        end,
    })
    table.insert(items, {
        text = _("清除全部缓存"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = string.format(_("确定清除所有番茄小说缓存?\n%d 本书, %d 章节将被删除。"), book_count, chapter_count),
                ok_text = _("清除"),
                cancel_text = _("取消"),
                ok_callback = function()
                    self.settings:clear_all_cache()
                    self:clearShelfCache()
                    _state.invalidateAllCache()
                    UIManager:show(InfoMessage:new{
                        text = _("缓存已清除"),
                    })
                end,
            })
        end,
    })
    return items
end

-- ===========================================================================
-- Download management
-- ===========================================================================

function M:showDownloadManager()
    local self_ref = self
    local dialog
    -- 定时刷新控制标志（Menu 关闭后停止刷新）
    local refresh_active = true

    -- 调试日志
    local task = _state.getDownloadTask()
    local history = _state.getDownloadHistory()
    if Log and Log.info then
        Log.info("[DownloadMgr] open: task=" .. tostring(task and task.book_title or "nil")
            .. " task_status=" .. tostring(task and task.status or "nil")
            .. " history_count=" .. tostring(#history))
    end

    -- 构建进度条文本（墨水屏友好的纯文本进度条）
    local function buildProgressText(current, total)
        if not total or total <= 0 then return "0%" end
        local pct = math.floor((current or 0) / total * 100)
        -- 10 格进度条，每格代表 10%
        local filled = math.floor(pct / 10)
        local bar = string.rep("█", filled) .. string.rep("░", 10 - filled)
        return string.format("%s %d%% (%d/%d)", bar, pct, current or 0, total)
    end

    -- 构建 Menu items
    local function buildItems()
        local items = {}
        local task = _state.getDownloadTask()
        if Log and Log.info then
            Log.info("[DownloadMgr] buildItems: task=" .. tostring(task and task.book_title or "nil")
                .. " status=" .. tostring(task and task.status or "nil"))
        end

        -- 当前下载任务
        -- 🔴 这一整屏的「纯展示行」必须用 `select_enabled = false`（**不是**
        --    `enabled_func`）。KOReader 的 `Menu:onMenuSelect` 只认
        --    `item.select_enabled == false` / `item.select_enabled_func`；
        --    写错字段名的后果不是「多点了没反应」这么轻 —— 点中之后仍然走
        --    `onMenuChoice`，紧接着 menu.lua 会调用 `self.close_callback()`，
        --    而这里的 close_callback 会把 refresh_active 置 false ⇒
        --    **用户在下载管理里随便点一行，进度就再也不自动刷新了**。
        if task and task.status == "downloading" then
            table.insert(items, {
                text = T(_("正在下载: 《%1》"), task.book_title or task.book_id or "未知"),
                select_enabled = false,
            })
            table.insert(items, {
                text = buildProgressText(task.current, task.total),
                select_enabled = false,
            })
            if task.chapter and task.chapter ~= "" then
                table.insert(items, {
                    text = T(_("当前: %1"), task.chapter),
                    select_enabled = false,
                    separator = true,
                })
            else
                table.insert(items, { text = "", separator = true })
            end
            table.insert(items, {
                text = _("取消下载"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("确定取消《%1》的下载?"), task.book_title or "未知"),
                        ok_text = _("确定"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            -- 走 state 的取消入口（而不是直接 clearDownloadTask）：
                            -- 下载流程注册的 handler 会**立刻掐掉当前章的子进程**并收尾。
                            -- 只清状态的话，正在跑的那一章要等它自己跑完
                            -- （图集/漫画单章 1~5 分钟）才停，看起来就像「取消没生效」。
                            if _state.requestDownloadCancel then
                                _state.requestDownloadCancel()
                            else
                                _state.clearDownloadTask()
                            end
                            self_ref:showInfo(_("已取消下载"))
                            -- 刷新列表
                            if dialog and dialog.updateItems then
                                dialog.item_table = buildItems()
                                dialog:updateItems()
                            end
                        end,
                    })
                end,
            })
            table.insert(items, { text = "", separator = true })
        else
            table.insert(items, {
                text = _("当前无下载任务"),
                select_enabled = false,
            })
            table.insert(items, { text = "", separator = true })
        end

        -- 历史下载记录
        local history = _state.getDownloadHistory()
        if #history > 0 then
            table.insert(items, {
                text = _("最近下载记录:"),
                select_enabled = false,
            })
            for i, h in ipairs(history) do
                local status_text = h.status == "completed" and _("完成")
                    or (h.status == "interrupted" and _("中断") or _("取消"))
                local time_str = h.end_time and os.date("%m-%d %H:%M", h.end_time) or ""
                table.insert(items, {
                    text = T(_("《%1》 - %2 %3"), h.book_title or h.book_id or "未知", status_text, time_str),
                    select_enabled = false,
                })
            end
            table.insert(items, { text = "", separator = true })
            table.insert(items, {
                text = _("清空历史记录"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("确定清空所有下载历史记录?"),
                        ok_text = _("确定"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            _state.clearDownloadHistory()
                            self_ref:showInfo(_("已清空历史记录"))
                            if dialog and dialog.updateItems then
                                dialog.item_table = buildItems()
                                dialog:updateItems()
                            end
                        end,
                    })
                end,
            })
        end

        if Log and Log.info then
            Log.info("[DownloadMgr] buildItems: items_count=" .. tostring(#items))
        end
        return items
    end

    -- 打开本菜单会**临时**顶掉 _state.active_menu（它同时被书架的关闭逻辑使用）。
    -- 关窗时必须把这个引用还回去，否则「从书架进下载管理再返回」会让
    -- _state.active_menu 变 nil —— 书架还在屏幕上，而依赖它的清理逻辑全部失效。
    local prev_active_menu = _state.active_menu

    dialog = Menu:new{
        title = _("下载管理"),
        item_table = buildItems(),
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            -- ⚠️ `close_callback` **不只在「菜单真的关掉」时**触发：koreader
            --    menu.lua 的 `Menu:onMenuSelect` 每选中一个条目也会调它。
            --    以前无条件 `refresh_active = false` ⇒ 用户在下载管理里点任何一行
            --    （哪怕只是点书名那条展示行），**进度从此不再自动刷新**，
            --    而且 active_menu 被顺手清空。这里用「菜单是否还在屏幕上」区分。
            if UIManager and type(UIManager.isWidgetShown) == "function" then
                local ok, shown = pcall(UIManager.isWidgetShown, UIManager, dialog)
                if ok and shown then return end
            end
            refresh_active = false
            if _state.active_menu == dialog then
                _state.active_menu = prev_active_menu
            end
        end,
    }
    _state.active_menu = dialog
    UIManager:show(dialog)

    -- 定时刷新当前下载进度（2秒间隔，墨水屏友好）
    local function refreshProgress()
        if not refresh_active then return end
        if not dialog then return end

        local task = _state.getDownloadTask()
        if task and task.status == "downloading" then
            -- 有下载任务，刷新列表
            dialog.item_table = buildItems()
            if dialog.updateItems then
                dialog:updateItems()
            end
            -- 继续定时刷新
            UIManager:scheduleIn(2, refreshProgress)
        else
            -- 下载完成或取消，最后刷新一次
            dialog.item_table = buildItems()
            if dialog.updateItems then
                dialog:updateItems()
            end
        end
    end

    -- 如果有下载任务，启动定时刷新
    local task = _state.getDownloadTask()
    if task and task.status == "downloading" then
        UIManager:scheduleIn(2, refreshProgress)
    end
end

function M:getCacheSizeMB()
    local total = 0
    local dir = self.settings:get_download_dir()
    local ok = pcall(function()
        local function walk(path)
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    local full = path .. "/" .. entry
                    local attr = lfs.attributes(full)
                    if attr then
                        if attr.mode == "directory" then
                            walk(full)
                        else
                            total = total + attr.size
                        end
                    end
                end
            end
        end
        walk(dir)
    end)
    return total / (1024 * 1024)
end

function M:clearAllCache()
    local dir = self.settings:get_download_dir()
    if not dir then
        self:showInfo(_("下载目录未设置"))
        return
    end

    -- 🔴 清缓存前必须先**停掉所有还会往这个目录写文件的异步链**，否则：
    --    ① 封面预下载（`_preloadAllCovers` / 页级 `cache_covers_step`）每下完一张就
    --       开一个新文件；`lfs.dir` 边删边被写入，遍历会提前结束
    --       ⇒ 实测「缓存已清除 共删除 1 个文件」，而目录里还剩一整个书架的书；
    --    ② 就算这一趟删干净了，后台链在几秒内又把封面全下回来，用户看到的还是「没清掉」。
    --    两条链都挂在 `_cancelCoverLoading()` 的 generation 上，翻 generation 即可让
    --    未完成的回调整段作废；再做一次按 tag 的硬取消，掐掉正在跑的子进程。
    pcall(function() self:_cancelCoverLoading() end)
    if Async and Async.cancel_tag then
        pcall(Async.cancel_tag, "covers")
    end

    local ProgressWidget = require("ui/widget/progresswidget")
    local progress = ProgressWidget:new{
        width = Screen and (Screen:getWidth() - 100) or nil,
        height = 8,
    }
    local progress_dialog = InfoMessage:new{
        text = _("正在清除缓存..."),
        timeout = 0,
        dismissable = false,
        icon = "info",
        additional_widgets = { progress },
    }
    UIManager:show(progress_dialog)

    local total_files = 0
    local function count_files(path)
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local full = path .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "directory" then
                        count_files(full)
                    end
                    total_files = total_files + 1
                end
            end
        end
    end
    count_files(dir)

    local removed_count = 0
    -- 进度条刷新节流：`forceRePaint()` 每次都要重画整屏，而这里可能删几千个文件
    -- （145 本书 × 每章 2 个文件 + 封面）。只在跨过 5% 台阶时刷一次，
    -- 既不卡 UI，又能让用户看到进度在动。
    local next_paint_at = 0.05
    local function remove_tree(path)
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local full = path .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "directory" then
                        remove_tree(full)
                        lfs.rmdir(full)
                    else
                        os.remove(full)
                    end
                    removed_count = removed_count + 1
                    if total_files > 0 then
                        local ratio = removed_count / total_files
                        if ratio >= next_paint_at then
                            next_paint_at = ratio + 0.05
                            -- 🔴 KOReader 的 ProgressWidget **没有** `setProgress`
                            --    （方法清单只有 setPercentage / getPercentageFromPosition …）。
                            --    此前写的 `progress:setProgress(x)` 每次都抛
                            --    「attempt to call method 'setProgress' (a nil value)」，
                            --    而唯一的调用点被 `pcall(remove_tree, dir)` 包着 ⇒ 错误被吞、
                            --    循环**在删除第 1 个文件后**就中断 ⇒ 用户看到
                            --    「缓存已清除 共删除 1 个文件」，磁盘上却一点没少。
                            --    pcall 只该兜「目录读到一半消失」这类真异常，不能替必修的 bug 兜底。
                            pcall(function() progress:setPercentage(math.floor(ratio * 100)) end)
                            UIManager:forceRePaint()
                        end
                    end
                end
            end
        end
    end

    -- 降级路径：真出了 IO 异常也要把「删了多少」如实报出来，而不是静默报成功。
    local ok_tree, tree_err = pcall(remove_tree, dir)
    UIManager:close(progress_dialog)
    if not ok_tree then
        if Log then Log.warn("[缓存管理] 清除缓存中断: " .. tostring(tree_err)) end
        self:showInfo(T(_("缓存已清除（中断）\n共删除 %1 个文件\n%2"),
            tostring(removed_count), tostring(tree_err):sub(1, 120)))
        return
    end
    self:showInfo(string.format(_("缓存已清除\n共删除 %d 个文件"), removed_count))
end


return M
