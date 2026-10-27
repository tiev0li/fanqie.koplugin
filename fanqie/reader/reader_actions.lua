-- fanqie/reader/reader_actions.lua —— 从 main.lua 按原函数边界拆分。
-- 方法名与实现保持原接口；共享依赖集中在 fanqie.runtime。

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Content = require("fanqie.content")
local FanQie = require("fanqie.fanqie")
local H = require("fanqie.helper")
local Log = require("fanqie.logger")
local Async = require("fanqie.async")
local Patches = require("patches.core")
local Runtime = require("fanqie.runtime")
local _state = Runtime.state
local display_error = Runtime.display_error
local now_seconds = Runtime.now_seconds
local getCurrentChapterIndex = Runtime.getCurrentChapterIndex
local getCachedChapters = Runtime.getCachedChapters

local M = {}

function M:reloadCurrentChapter()
    local book = _state.current_book
    local chapters = _state.current_chapters
    local current_idx = _state.current_chapter_index
    
    if not book or not chapters or not current_idx then
        self:showInfo(_("没有可重新获取的章节"))
        return
    end
    
    local chapter = chapters[current_idx]
    if not chapter then return end
    
    local item_id = tostring(chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    local existing_path = cached_chapters[item_id]
    
    -- Delete cached file if exists
    if existing_path and H.file_exists(existing_path) then
        os.remove(existing_path)
        if Log then Log.info("deleted cached chapter:", item_id) end
    end
    
    -- Also try to delete from expected location
    local expected_path = Content.book_cache_dir(self.settings, book.book_id) .. "/chapter_" .. item_id .. ".html"
    if H.file_exists(expected_path) then
        os.remove(expected_path)
        if Log then Log.info("deleted expected chapter file:", item_id) end
    end

    -- 删除段评数据索引文件，确保重新获取
    local para_reviews_path = Content.book_cache_dir(self.settings, book.book_id) .. "/para_reviews_" .. item_id .. ".lua"
    if H.file_exists(para_reviews_path) then
        os.remove(para_reviews_path)
        if Log then Log.info("deleted para_reviews index:", item_id) end
    end
    _state.clearParaReviews()

    -- Clear cache index entry
    cached_chapters[item_id] = nil
    Content.save_cache_index(self.settings, book.book_id, cached_chapters)
    
    -- Re-download
    self:navigateToChapter(book, chapters, current_idx, {
        error_message = "重新获取章节失败:\n%1",
    })
end

function M:preDownloadChapters(book, chapters, current_index)
    -- 唯一读取口径（helper.prefetch_count）；0 = 关闭预下载
    local pre_download_count = H.prefetch_count(self.settings)
    local total = #chapters

    if current_index >= total then
        _state.pre_download_triggered = false
        return
    end
    if pre_download_count <= 0 then
        -- 关闭预下载：清标志，避免 onPageUpdate 里反复进入本函数
        _state.pre_download_triggered = false
        if Log then Log.info("[FanQie] pre-download disabled (pre_download_chapters=0)") end
        return
    end

    -- 段评模式：预下载也传递 review=true；skip_cache_index 由父进程统一持久化索引
    local review_enabled = _state.isReviewEnabled()
    -- heartbeat_path：见 _downloadHeartbeatPath 的注释（图集/漫画整章下载不能被
    -- 「总时长」超时掐掉，只要还有图在落盘就续期）。
    local fetch_opts = {
        skip_cache_index = true,
        heartbeat_path = self:_downloadHeartbeatPath(book),
    }
    if review_enabled then fetch_opts.review = true end
    -- 段评「整段可点」（v2.16.24）：段落正文也包成锚接
    -- （点段落任意位置即可打开该段评论），设置里可关。
    if self.settings and self.settings.getParaTapWhole then
        fetch_opts.para_tap_whole = self.settings:getParaTapWhole() ~= false
    end

    local cached_chapters = getCachedChapters(self, book)
    local client = self.client
    local settings = self.settings
    -- 本次批量里「真正发过请求」的章节数：只有它参与批量休息计数
    -- （跳过缓存的章节不发请求，不该占用节流额度）。
    local processed = 0

    if Log then
        Log.info("[FanQie] pre-download start: count=" .. tostring(pre_download_count)
            .. " from=" .. tostring(current_index) .. "/" .. tostring(total)
            .. " review=" .. tostring(review_enabled))
    end

    -- 顺序下载：每章在子进程执行（HTTP + 图片下载 + 落盘均在子进程），
    -- 父进程 UI 线程只做轻量轮询，不再因预下载卡顿阅读。
    local function download_one(offset)
        if _state.is_downloading then
            -- 用户正在主动下载章节，稍后重试
            UIManager:scheduleIn(1.0, function()
                download_one(offset)
            end)
            return
        end

        if offset > pre_download_count or current_index + offset > total then
            _state.pre_download_triggered = false
            Log.debug("pre-download: batch completed")
            return
        end

        local target_idx = current_index + offset
        local chapter = chapters[target_idx]
        local item_id = tostring(chapter.itemId)

        local already_cached = cached_chapters[item_id] and H.file_exists(cached_chapters[item_id])
        -- 已缓存正文直接跳过：段评数据缺失不触发重下

        if already_cached then
            Log.debug("pre-download: chapter", target_idx, "already cached")
            UIManager:scheduleIn(0, function() download_one(offset + 1) end)
            return
        end

        Log.info("pre-download: starting download for chapter", target_idx)
        local b = { book_id = book.book_id, title = book.title, author = book.author }
        -- 置 is_downloading：让 onEndOfBook/navigateToChapter 感知预下载进行中，
        -- 避免与它们重复下载同一章；on_done 中先清零再调度下一章。
        _state.is_downloading = true
        Async.run(function()
            -- 子进程内执行：抓取正文 + 段评 + 图片下载 + 保存 HTML
            -- skip_cache_index=true，不写共享 cache_index.lua（由父进程统一持久化）
            local path, _ch, _rev, rate_info = Content.fetch_chapter_html(client, settings, b, chapter, fetch_opts)
            return { path = path, rate_info = rate_info }
        end, function(ok, result, err)
            -- 先清零，确保调度下一章时 download_one 不会被自己卡住
            _state.is_downloading = false
            local path = type(result) == "table" and result.path or nil
            if ok and type(result) == "table" and result.rate_info then
                local ok_sm, SM = pcall(require, "fanqie.sources")
                if ok_sm and SM and SM.merge_rate_limit_timestamps then
                    SM.merge_rate_limit_timestamps(result.rate_info)
                end
            end
            if ok and path then
                cached_chapters[item_id] = path
                -- 父进程统一持久化完整索引，避免与子进程争写
                Content.save_cache_index(settings, book.book_id, cached_chapters)
                Log.info("pre-download: completed chapter", target_idx)
            else
                Log.warn("pre-download: failed chapter", target_idx, ":", err)
            end
            -- 继续下一章：间隔 = 基础间隔 + 随机抖动，每 N 章再长休一次
            -- （参数见 helper.next_request_delay / settings.cache.request_*）。
            -- 失败也算「发过请求」，一并计数。
            processed = processed + 1
            local delay = H.next_request_delay(settings, processed)
            UIManager:scheduleIn(delay, function() download_one(offset + 1) end)
        end, { poll_interval = 0.2, timeout = 60 })
    end

    -- Delay start so user sees the current chapter first
    UIManager:scheduleIn(2.0, function()
        download_one(1)
    end)
end

-- Get current page progress within the chapter (0.0 - 1.0)
function M:getCurrentPageProgress()
    if self.ui and self.ui.document then
        local doc = self.ui.document
        if doc.info and doc.info.number_of_pages and doc.info.number_of_pages > 0 then
            local current_page = self.ui.state and self.ui.state.page or 1
            return math.min(current_page / doc.info.number_of_pages, 1.0)
        end
    end
    return 0
end

-- 按 item_id 在目录里找它的 1-based 序号（找不到返回 nil）。
--
-- 🔴 为什么需要它：切章时 `_state.current_chapter_index` 是**新章**，
--    而「补发旧文档进度」要的是**旧章**的序号 —— 只能按 item_id 反查（见 onCloseDocument）。
function M:_chapterIndexByItemId(chapters, item_id)
    if not chapters or item_id == nil then return nil end
    local want = tostring(item_id)
    for i, ch in ipairs(chapters) do
        if ch and ch.itemId ~= nil and tostring(ch.itemId) == want then
            return i
        end
    end
    return nil
end

-- 当前文档对应的章节 item_id（路径反查 `<cache>/<book_id>/chapter_<item_id>.html`）。
function M:_currentDocChapterItemId()
    if not (self.ui and self.ui.document) then return nil end
    if type(_state.item_id_from_path) ~= "function" then return nil end
    return _state.item_id_from_path(self.ui.document.file or self.ui.document.path)
end

-- Sync reading progress to server（章节结束 / 关文档 / 定期上传都走这里）
-- 通过 Async 子进程上传，HTTP 请求在子进程执行，UI 线程仅做轻量轮询，
-- 不再阻塞界面（消除章节开始 / 每 10 页时的几秒卡顿）。
--
-- @param opts table|nil
--   opts.item_id   要上传**哪一章**（默认当前章）。
--                  🔴 切章时旧文档关闭的那一刻 `current_chapter_index` 已经是新章，
--                  所以 onCloseDocument 必须显式传「这份文档所属的章节」；
--                  不传就会把旧章的页进度写成新章的进度（末页翻章 ⇒ 新章被标记成已读完）。
--                  传了但目录里找不到该章 ⇒ 直接放弃（宁可不上传，也别写到错的章上）。
--   opts.progress  页进度（默认按当前文档的阅读位置算）
function M:syncCurrentProgress(opts)
    opts = opts or {}
    if not _state.current_book or not _state.current_chapters then return end
    local chapters = _state.current_chapters
    local idx
    if opts.item_id ~= nil then
        idx = self:_chapterIndexByItemId(chapters, opts.item_id)
        if not idx then
            -- 目录里没有这一章（目录刚刷新过 / 章节已下架）⇒ 不猜，也不写到别的章上
            if Log then
                Log.warn("syncCurrentProgress: item_id 不在目录里，跳过", tostring(opts.item_id))
            end
            return
        end
    else
        idx = _state.current_chapter_index
    end
    if not idx or idx < 1 then return end
    local chapter = chapters[idx]
    if not chapter or not chapter.itemId or not _state.current_book.book_id then
        return
    end
    local progress = opts.progress or self:getCurrentPageProgress()
    local last_report = _state.getLastProgressReport(chapter.itemId)
    if last_report and last_report.progress >= progress then
        return
    end

    -- 提前拷贝，避免子进程闭包依赖可变的全局状态
    local book_id = _state.current_book.book_id
    local item_id = chapter.itemId
    local chapter_idx = idx - 1
    local client = self.client
    local start_time = now_seconds()

    -- 🔴 发起的那一刻就登记 pending：Async 的轮询由 UIManager 驱动，
    --    进程在「在途」时退出（关 KOReader / 掉电 / 被杀）⇒ on_done 永不执行
    --    ⇒ 只在失败回调里登记 = **静默丢进度**。成功后再 remove（见下方 on_done）。
    _state.addPendingProgress(book_id, item_id, chapter_idx, progress)

    Async.run(function()
        -- 在子进程中执行阻塞 HTTP POST
        client:update_read_progress(book_id, item_id, chapter_idx, progress)
        return true
    end, function(ok, _result, err)
        Log.info("syncCurrentProgress completed in",
            string.format("%.3f", now_seconds() - start_time), "seconds")
        if ok then
            _state.setLastProgressReport(item_id, progress)
            _state.removePendingProgress(book_id, item_id)
        else
            if Log then Log.warn("syncCurrentProgress failed:", err) end
            -- 重新登记（幂等）+ 落盘：重启后还能补上这一次
            _state.addPendingProgress(book_id, item_id, chapter_idx, progress)
            _state.persistPendingProgress()
        end
    end, { delay = 0.1, poll_interval = 0.2, timeout = 30, tag = "progress" })
end

-- Retry pending progress reports when network is available
-- 每条待上传进度在子进程执行，顺序处理，UI 线程不阻塞。
function M:retryPendingProgress()
    local book_id = _state.current_book and _state.current_book.book_id
    if not book_id then return end

    local start_time = now_seconds()
    UIManager:scheduleIn(0.5, function()
        local pending = _state.getPendingProgress()
        -- 收集本书的待上传条目为顺序列表
        local queue = {}
        for key, item in pairs(pending) do
            if item.book_id == book_id then
                table.insert(queue, item)
            end
        end
        local total = #queue
        if total == 0 then return end

        local client = self.client
        local function process_next(i)
            if i > total then
                Log.info("retryPendingProgress completed", total,
                    "items in", string.format("%.3f", now_seconds() - start_time), "seconds")
                return
            end
            local item = queue[i]
            Async.run(function()
                client:update_read_progress(item.book_id, item.item_id, item.chapter_idx, item.progress)
                return true
            end, function(ok, _r, err)
                if ok then
                    _state.setLastProgressReport(item.item_id, item.progress)
                    _state.removePendingProgress(item.book_id, item.item_id)
                else
                    if Log then Log.warn("retryPendingProgress item failed:", item.item_id, err) end
                end
                -- 处理下一条
                UIManager:scheduleIn(0, function() process_next(i + 1) end)
            end, { poll_interval = 0.2, timeout = 30, tag = "progress" })
        end
        process_next(1)
    end)
end

function M:onPageUpdate(pageno)
    if not _state.current_book or not _state.current_chapters then
        return
    end
    if not self:isCurrentDocFanqie() then
        return
    end

    if not self.ui or not self.ui.document then return end

    local doc = self.ui.document
    local total_pages = doc:getPageCount()
    if not total_pages or total_pages <= 0 then return end

    _state.last_page_number = pageno
    local Session = require("fanqie.reading_session")
    Session.record(self)

    -- 阅读中定期上传（幂等）：只在用户真的在翻页时确认定时器活着。
    -- 关文档 / 切章会把它停掉，下一次翻页再重新挂上。
    self:_ensureProgressTimer()

    -- Only trigger pre-download after user has read past 50% of the chapter
    -- This avoids triggering immediately on chapter open for short chapters
    local progress = pageno / total_pages
    if progress > 0.5 and not _state.pre_download_triggered then
        _state.pre_download_triggered = true
        UIManager:scheduleIn(1.0, function()
            self:preDownloadChapters(_state.current_book, _state.current_chapters, _state.current_chapter_index)
        end)
    end

    if pageno % 10 == 0 then
        self:syncCurrentProgress()
    end
end

-- Handle "previous chapter" signal from patched ReaderPaging.
-- Triggered only when user presses "previous page" while on page 1.
function M:onFanQiePrevChapter()
    if not _state.current_book or not _state.current_chapters then
        return false
    end
    if not self:isCurrentDocFanqie() then
        return false
    end

    if _state.start_of_chapter_triggered then
        return false
    end

    local current_idx = getCurrentChapterIndex()
    if current_idx <= 1 then
        UIManager:show(InfoMessage:new{
            text = _("已经是第一章了"),
            timeout = 3,
        })
        return true
    end

    _state.start_of_chapter_triggered = true
    _state.setChapterNavigating(true)

    local prev_idx = current_idx - 1
    local chapters = _state.current_chapters
    local book = _state.current_book
    local prev_chapter = chapters[prev_idx]
    if not prev_chapter then
        _state.start_of_chapter_triggered = false
        return true
    end

    local item_id = tostring(prev_chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    -- 索引命中也要就地升级（见 Content.ensure_chapter_upgraded）
    local existing_path = Content.ensure_chapter_upgraded(self.settings, cached_chapters[item_id])
    local path = existing_path

    -- 段评模式：段评开关决定首次下载是否带段评；已缓存正文直接用，缺段评不重下
    local review_enabled = _state.isReviewEnabled()
    -- heartbeat_path：见 _downloadHeartbeatPath 的注释（图集/漫画整章下载不能被
    -- 「总时长」超时掐掉，只要还有图在落盘就续期）。
    local fetch_opts = {
        skip_cache_index = true,
        heartbeat_path = self:_downloadHeartbeatPath(book),
    }
    if review_enabled then fetch_opts.review = true end
    -- 段评「整段可点」（v2.16.24）：段落正文也包成锚接
    -- （点段落任意位置即可打开该段评论），设置里可关。
    if self.settings and self.settings.getParaTapWhole then
        fetch_opts.para_tap_whole = self.settings:getParaTapWhole() ~= false
    end

    -- 下载完成后的跳章逻辑（缓存命中与异步下载共用）
    local function finish_prev(p)
        -- 加载段评数据
        if review_enabled then
            local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
            _state.setCurrentParaReviews(reviews)
        end
        _state.current_chapter_index = prev_idx
        _state.pre_download_triggered = false
        _state.last_page_number = nil
        self:showReaderUI(p, prev_chapter)
        UIManager:scheduleIn(1.0, function()
            _state.start_of_chapter_triggered = false
            self:syncCurrentProgress()
            self:preDownloadChapters(book, chapters, prev_idx)
            self:retryPendingProgress()
        end)
    end

    if not existing_path or not H.file_exists(existing_path) then
        -- Try to find file directly from filesystem
        local found_path = Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found_path then
            cached_chapters[item_id] = found_path
            Content.save_cache_index(self.settings, book.book_id, cached_chapters)
            path = found_path
        else
            self:showBusy(T(_("正在下载: %1"), prev_chapter.title or ""))
            local b = { book_id = book.book_id, title = book.title, author = book.author }
            local client = self.client
            local settings = self.settings
            Async.run(function()
                local path, _ch, _rev, rate_info = Content.fetch_chapter_html(client, settings, b, prev_chapter, fetch_opts)
                return { path = path, rate_info = rate_info }
            end, function(ok, result, err)
                self:closeBusy()
                if not ok or type(result) ~= "table" or not result.path then
                    Log.error("onFanQiePrevChapter download failed:", tostring(err or result))
                    _state.start_of_chapter_triggered = false
                    _state.setChapterNavigating(false)
                    self:showError(T(_("加载上一章失败:\n%1"), display_error(err or result)))
                    return
                end
                -- 合并子进程记录的限流时间戳（子进程退出即丢失）
                if result.rate_info then
                    local ok_sm, SM = pcall(require, "fanqie.sources")
                    if ok_sm and SM and SM.merge_rate_limit_timestamps then
                        SM.merge_rate_limit_timestamps(result.rate_info)
                    end
                end
                local cc = getCachedChapters(self, book)
                cc[item_id] = result.path
                Content.save_cache_index(settings, book.book_id, cc)
                finish_prev(result.path)
            end, { delay = 0.1, poll_interval = 0.2, timeout = 60 })
            return true  -- 异步下载，完成后跳章
        end
    end

    finish_prev(path)
    return true
end

function M:onEndOfBook()
    if not _state.current_book or not _state.current_chapters then
        return false
    end
    
    local is_fanqie = self:isCurrentDocFanqie()
    if not is_fanqie then
        return false
    end

    -- 重入保护：异步跳章期间，忽略末页重复触发的事件，避免重复下载下一章
    if _state.end_of_book_jumping then
        return true
    end

    local current_idx = getCurrentChapterIndex()
    local chapters = _state.current_chapters
    local book = _state.current_book

    if book.book_id and current_idx > 0 then
        local chapter = chapters[current_idx]
        if chapter and chapter.itemId then
            -- 本章读完 ⇒ 进度 1.0。统一走 syncCurrentProgress：
            --   · **显式传 item_id**：末页这一刻 current_chapter_index 还是本章，
            --     但显式传号让「补发 / 定期上传 / 读完」三种来源的口径完全一致；
            --   · tag / last_report 守卫 / pending 登记都在那边统一处理。
            self:syncCurrentProgress({ item_id = chapter.itemId, progress = 1.0 })
        end
    end

    local next_idx = current_idx + 1

    if next_idx > #chapters then
        UIManager:show(InfoMessage:new{
            text = _("已经是最后一章了"),
            timeout = 3,
        })
        return true
    end

    local next_chapter = chapters[next_idx]
    if not next_chapter then
        return true
    end

    -- 下一章切换：段评获取与正文下载在子进程执行，UI 线程保持响应。
    -- busy 对话框期间界面不冻结；事件返回 true 使文档保持打开，
    -- 异步完成后由 finish_next 跳转下一章。
    _state.setChapterNavigating(true)
    local item_id = tostring(next_chapter.itemId)
    local review_enabled = _state.isReviewEnabled()
    -- heartbeat_path：见 _downloadHeartbeatPath 的注释（图集/漫画整章下载不能被
    -- 「总时长」超时掐掉，只要还有图在落盘就续期）。
    local fetch_opts = {
        skip_cache_index = true,
        heartbeat_path = self:_downloadHeartbeatPath(book),
    }
    if review_enabled then fetch_opts.review = true end
    -- 段评「整段可点」（v2.16.24）：段落正文也包成锚接
    -- （点段落任意位置即可打开该段评论），设置里可关。
    if self.settings and self.settings.getParaTapWhole then
        fetch_opts.para_tap_whole = self.settings:getParaTapWhole() ~= false
    end

    -- 下载完成后的跳章逻辑（缓存命中与异步下载共用）
    local function finish_next(p)
        -- 加载段评数据
        if review_enabled then
            local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
            _state.setCurrentParaReviews(reviews)
        end
        _state.current_chapter_index = next_idx
        _state.pre_download_triggered = false
        self:showReaderUI(p, next_chapter)
        UIManager:scheduleIn(1.0, function()
            self:preDownloadChapters(book, chapters, next_idx)
            self:retryPendingProgress()
        end)
    end

    -- 解析下一章缓存路径（已缓存正文直接用，缺段评不重下；文件系统回退查找）
    local function resolve_cached_path()
        local cached_chapters = getCachedChapters(self, book)
        -- 索引命中也要就地升级（见 Content.ensure_chapter_upgraded）
        local p = Content.ensure_chapter_upgraded(self.settings, cached_chapters[item_id])
        if p and H.file_exists(p) then
            return p
        end
        local found = Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found then
            local cc = getCachedChapters(self, book)
            cc[item_id] = found
            Content.save_cache_index(self.settings, book.book_id, cc)
            return found
        end
        return nil
    end

    -- 1) 快速路径：缓存命中直接跳章（同步完成，无需重入保护）
    local cached_path = resolve_cached_path()
    if cached_path then
        finish_next(cached_path)
        return true
    end

    -- 2) 异步下载路径：标记重入，避免末页重复触发下载同一章
    _state.end_of_book_jumping = true

    local b = { book_id = book.book_id, title = book.title, author = book.author }
    local client = self.client
    local settings = self.settings

    -- showBusy 幂等包装：等待路径可能已显示 busy，避免重复 show 泄漏对话框
    local function ensure_busy(text)
        if not self._busy_msg then
            self:showBusy(text)
        end
    end

    -- 启动下载：同时置 is_downloading，让预下载 download_one 检测后延后重试，
    -- 避免与预下载争用同一书源限流配额 / 争写缓存索引。
    local function start_download()
        _state.is_downloading = true
        ensure_busy(T(_("正在下载: %1"), next_chapter.title or ""))
        Async.run(function()
            local path, _ch, _rev, rate_info = Content.fetch_chapter_html(client, settings, b, next_chapter, fetch_opts)
            return { path = path, rate_info = rate_info }
        end, function(ok, result, err)
            self:closeBusy()
            if not ok or type(result) ~= "table" or not result.path then
                Log.error("onEndOfBook download failed:", tostring(err or result))
                _state.is_downloading = false
                _state.end_of_book_jumping = false
                _state.setChapterNavigating(false)
                self:showError(T(_("加载下一章失败:\n%1"), display_error(err or result)))
                return
            end
            -- 合并子进程记录的限流时间戳（子进程退出即丢失）
            if result.rate_info then
                local ok_sm, SM = pcall(require, "fanqie.sources")
                if ok_sm and SM and SM.merge_rate_limit_timestamps then
                    SM.merge_rate_limit_timestamps(result.rate_info)
                end
            end
            local cc = getCachedChapters(self, book)
            cc[item_id] = result.path
            Content.save_cache_index(settings, book.book_id, cc)
            _state.is_downloading = false
            _state.end_of_book_jumping = false
            finish_next(result.path)
        end, { delay = 0.1, poll_interval = 0.2, timeout = 60 })
    end

    -- 若预下载正在进行（is_downloading=true），先等待其完成再决定是否需要自己下载：
    -- 预下载可能正在下载本章，完成后即可走缓存命中路径，避免重复下载。
    -- 每轮先查缓存，命中即跳；未命中且仍有下载在进行则继续等（最多 ~60s）。
    if _state.is_downloading then
        ensure_busy(T(_("正在准备: %1"), next_chapter.title or ""))
        local waits = 0
        local function wait_then_download()
            -- 优先查缓存：预下载可能已缓存本章
            local p = resolve_cached_path()
            if p then
                self:closeBusy()
                _state.end_of_book_jumping = false
                finish_next(p)
                return
            end
            if _state.is_downloading then
                waits = waits + 1
                if waits > 120 then
                    -- 等待超时（is_downloading 异常卡死），强制自己下载
                    Log.warn("onEndOfBook: wait for is_downloading timeout, force download")
                    start_download()
                    return
                end
                UIManager:scheduleIn(0.5, wait_then_download)
                return
            end
            -- 无下载在进行且未缓存，自己下载
            start_download()
        end
        UIManager:scheduleIn(0.5, wait_then_download)
    else
        start_download()
    end
    return true  -- 事件已处理，文档保持打开，异步完成后跳章
end

-- 进度会话收尾：只掐「进度上传」这一条异步链（tag="progress"），
-- 跳章 / 预下载 / 书架刷新 / 封面不受影响（那是 onExit 的 cancel_all 才管的范围）。
-- 场景：切章与关文档都会瞬间发起多次上传，旧的在途请求会带着旧进度迟到回填，
-- 覆盖掉刚写的收尾值。先取消、再补发，保证最后落地的是当前状态。
function M:_finalizeProgressSession()
    if Async and Async.cancel_tag then
        pcall(function() Async.cancel_tag("progress") end)
    end
end

-- 「关闭时上传进度」开关（settings.sync.upload_on_close，默认 true）。
-- 这个配置项以前是**死的**（全仓库只有默认值定义、没有任何消费点，设置页也看不到），
-- 于是用户以为关掉了其实一直在传。
function M:_uploadOnCloseEnabled()
    if not (self.settings and self.settings.get) then return true end
    local ok, sync = pcall(function() return self.settings:get("sync", {}) end)
    if not ok or type(sync) ~= "table" then return true end
    return sync.upload_on_close ~= false
end

-- 阅读中定期上传的间隔（秒）。0 / 非法值 = 关闭。
function M:_progressUploadInterval()
    if not (self.settings and self.settings.get) then return 0 end
    local ok, sync = pcall(function() return self.settings:get("sync", {}) end)
    if not ok or type(sync) ~= "table" then return 0 end
    local minutes = tonumber(sync.upload_interval_minutes) or 0
    if minutes <= 0 then return 0 end
    return math.max(60, math.floor(minutes * 60))
end

-- 当前活跃的插件实例。
--
-- 🔴 为什么不能直接用闭包里的 self：切章会重建 ReaderUI（连带重建插件实例），
--    旧实例的 `self.ui` 指向已销毁的 ReaderUI ⇒ `getCurrentPageProgress()` 返回 0
--    ⇒ 拿它上传等于**把进度刷成 0**。所以定时器每次 tick 都从 ReaderUI.instance
--    现取活跃实例（ReaderUI:registerModule 会把它挂成 `instance.fanqie`）。
local function active_plugin_instance()
    local ok, RUI = pcall(require, "apps/reader/readerui")
    if ok and type(RUI) == "table" and RUI.instance then
        return RUI.instance.fanqie
    end
    return nil
end

-- 阅读中定期上传（settings.sync.upload_interval_minutes，0 = 关闭）。
-- 幂等：翻页时反复调用只会挂一个定时器链；关文档时由 _stopProgressTimer 撤掉。
--
-- 🔴 这也是「进度有时候丢」的主因之一：以前只在「末页 / 关文档 / 开目录」
--    三个时刻上传，读到一半退出 KOReader（或切到别的书、被系统杀掉）这段进度
--    就没了 —— README 里承诺的「阅读中定期上传」在这之前其实并不存在。
function M:_ensureProgressTimer()
    local seconds = self:_progressUploadInterval()
    if seconds <= 0 then
        self:_stopProgressTimer()
        return
    end
    if _state.progress_timer_on then return end
    _state.progress_timer_on = true
    -- 🔴 代际 token：切章会先 stop 再 start，旧 tick 闭包必须能认出「我已经被换掉」，
    --    否则新旧两条定时器链会并存（上传频率翻倍）。
    _state.progress_timer_token = (_state.progress_timer_token or 0) + 1
    local my_token = _state.progress_timer_token
    if Log then Log.info("progress upload timer started, every", seconds, "s") end

    local function tick()
        if _state.progress_timer_token ~= my_token then return end
        local plugin = active_plugin_instance()
        if plugin and plugin.syncCurrentProgress and plugin:isCurrentDocFanqie() then
            plugin:syncCurrentProgress()
        end
        UIManager:scheduleIn(seconds, tick)
    end
    UIManager:scheduleIn(seconds, tick)
end

function M:_stopProgressTimer()
    _state.progress_timer_on = false
    _state.progress_timer_token = (_state.progress_timer_token or 0) + 1
end

function M:onCloseDocument()
    -- 🔴 必须放在最前面：这不依赖「当前文档是不是番茄的」——
    --    只要覆盖过（`_state.end_document_action_backup ~= nil`）就要还回去，
    --    否则「到达文档末尾时的操作」会被永久改成 nothing（影响用户读别的书）。
    --    下面那个 `isCurrentDocFanqie` 守卫在文档已经不在时可能为假，
    --    所以还原不能写在守卫后面。
    --    本钩子切章时也会走 —— 那次还原之后，新文档的 ReaderReady 会立刻重新覆盖
    --    （showReader 的 doShowReader 在同一同步块里 onClose + new + show），
    --    中间窗口内不会有翻页发生，所以不会漏挡。
    local ok_restore, err_restore = pcall(function() self:_restoreEndDocumentAction() end)
    if not ok_restore and Log and Log.error then
        Log.error("restore end_document_action failed:", tostring(err_restore))
    end
    if not self:isCurrentDocFanqie() then
        return
    end
    -- 🔴 这个钩子**切章时也会走**：showReaderUI 用的是 `ReaderUI:showReader`
    --    （不是 switchDocument），它的 doShowReader 里会
    --    `ReaderUI.instance:onClose()` ⇒ 派发 CloseDocument ⇒ 走到这里。
    --    而 navigateToChapter 早在这之前就把 `_state.current_chapter_index`
    --    改成了**新章**。所以补发必须按「**这份文档**属于哪一章」取号
    --    （从文档路径反查），否则会把旧章的页进度上传成新章的进度：
    --    末页翻章时 progress≈1.0，等于把新章标记成「已读完」——
    --    这就是「上传进度有时候不对」的来源。
    local doc_item_id = self:_currentDocChapterItemId()
    require("fanqie.reading_session").record(self, true)
    -- 🔴 必须在这里（清状态之前、任何分支之前）取快照：
    --    「点开始阅读 → 子进程下载章节 → showReaderUI」这段窗口里也会走到
    --    CloseDocument，此时阅读器还没建立。只有进入本钩子时文档**确实已打开**，
    --    后面的「要加入书架吗」「关闭后回书架」才有意义。
    local was_open = _state.document_opened == true
    -- 对齐 koobone 的 end_session：先取消在途上传，再强制补发最后一次进度。
    -- （cancel 会让在途那条的 on_done 不再执行、last_report 不更新，
    --   因此下面这行 syncCurrentProgress 必然真的发包。）
    self:_finalizeProgressSession()
    self:_stopProgressTimer()
    if self:_uploadOnCloseEnabled() then
        self:syncCurrentProgress({ item_id = doc_item_id })
    end
    -- 还没传成功的进度落盘，下次启动能补
    _state.persistPendingProgress()
    -- 离开这本书时，若它不在书架，问一次「是否加入书架」。
    -- ⚠️ 必须在清状态**之前**调用：它要用 getCurrentBook() 取书号与书名。
    -- ⚠️ 本钩子切章时也会走到，切章不算「离开」—— 过滤逻辑在函数内部
    --    （延后一拍看 ReaderUI.instance 是否还在），见那里的注释。
    -- ⚠️ 包 pcall：这是关文档路径，弹窗/查询出任何错都不能连累进度收尾。
    local ok_prompt, err_prompt = pcall(function() self:_promptAddShelfOnLeave(was_open) end)
    if not ok_prompt and Log and Log.error then
        Log.error("add-shelf prompt failed:", tostring(err_prompt))
    end
    -- 「关闭阅读后回书架」（可在设置里关掉）。
    -- 🔴 用上面那个 was_open 快照做门控（见定义处的注释）。
    local ok_shelf, err_shelf = pcall(function() self:_returnToShelfAfterClose(was_open) end)
    if not ok_shelf and Log and Log.error then
        Log.error("return-to-shelf after close failed:", tostring(err_shelf))
    end
    _state.current_document_path = nil
    _state.setTocMenuOpen(false)
    _state.pre_download_triggered = false
    _state.last_page_number = nil
    _state.document_opened = false
    _state.setChapterNavigating(false)
end

-- 「关闭阅读后回书架」：真正退出阅读界面时，自动把番茄书架打开。
--
-- @param was_open boolean  进入 onCloseDocument 时文档是否**确实已经打开**。
--   🔴 这个门控不能省：「点开始阅读」→ 章节子进程下载 → showReaderUI 之间，
--     阅读器尚不存在，而这条路径上也会走到 CloseDocument。只看
--     `ReaderUI.instance` 是否为空会把「正在打开」误判成「已经关闭」，
--     用户看到的就是「点阅读自动回书架」。
--
-- 判据除此之外与 `_promptAddShelfOnLeave` 一致：延后一拍看
-- `ReaderUI.instance` 是否还在 —— 切章/换书时新实例在同一同步块里已经
-- show 出去，instance 仍在 ⇒ 不算离开；真退出时 instance 被置 nil。
--
-- ⚠️ Android 版 KOReader 关闭最后一个窗口会直接退出 App，此时本回调不会执行；
--    那条路径由「返回书架」菜单项（先开书架再关阅读器）覆盖。
function M:_returnToShelfAfterClose(was_open)
    if was_open ~= true then
        return
    end
    if self.settings:get("return_to_shelf_on_close", true) == false then
        return
    end
    -- KOReader 正在退出：不要在这个当口再插一层书架窗口。
    if _state.exiting then
        return
    end
    -- 正在从「返回书架」菜单项/手势进来：书架已经先压上去了，不要再开一次。
    if _state.returning_to_shelf then
        return
    end
    -- 🔴 插件自己正在切文档（上一章 / 下一章 / 跳章 / 开书）：这不是「用户离开了阅读」。
    --    切章路径 `showReaderUI → ReaderUI:showReader` 的实际顺序是
    --      「先 onClose 旧实例（派发 CloseDocument）→ 下一个 tick 才 new 新实例」，
    --    下一次 tick 时 `ReaderUI.instance` 恰好是 nil ⇒ 下面那个「延后一拍看
    --    instance 还在不在」的判据扛不住，会把切章误判成真退出、把书架盖到新章上。
    --    `was_open` 也拦不住（旧文档确实开着）。标志在新文档 ReaderReady 清除，
    --    见 fanqie/state.lua 的 switching_document 说明。
    --    ⚠️ 这里**只是不再自动开书架**，进度补传 / 加书架询问等收尾照常走。
    if _state.switching_document then
        if Log then Log.info("[FanQie] switching document, skip auto shelf") end
        return
    end
    local self_ref = self

    local function open_shelf()
        if type(self_ref.showBookshelf) ~= "function" then return end
        -- 书架底下垫一层文件管理器：书架是这里唯一会打开的窗口，
        -- 用户再点 X 时不会因为栈空而退出 App（见 _ensureShelfBackdrop）。
        if type(self_ref._ensureShelfBackdrop) == "function" then
            pcall(function() self_ref:_ensureShelfBackdrop(true) end)
        end
        -- 静默：已经是「读完关闭 → 回书架」的收尾，不该再弹「正在刷新书架...」。
        pcall(function() self_ref:showBookshelf({ silent = true }) end)
    end

    UIManager:nextTick(function()
        local ok_rui, RUI = pcall(require, "apps/reader/readerui")
        if ok_rui and RUI and RUI.instance then
            -- 还在阅读界面（切章 / 换书）：不是「关闭后」，不触发。
            return
        end
        -- 🔴 必须在**这一刻**就把垫底窗口放好：Android 版主循环在任务处理完后
        --    发现窗口栈为空会直接 quit，等到下面的 scheduleIn(0.1) 就晚了。
        if type(self_ref._ensureShelfBackdrop) == "function" then
            pcall(function() self_ref:_ensureShelfBackdrop(true) end)
        end
        -- 等界面层彻底收尾（onCloseWidget / 进度上传对话框等）再开书架。
        UIManager:scheduleIn(0.1, open_shelf)
    end)
end

-- 收尾界面层：把本插件自己 show 出来的顶层对话框收干净。
--
-- 🔴 每一步都是「先摘引用、再关对象」，且一律走 H.close_widget（只关还在
--    UIManager 栈上的）。直接 UIManager:close(已关过的 dialog) 会照常派发
--    CloseWidget 事件，副作用是给那块区域排一次 flashui 全刷 ——
--    这正是「弹窗偶尔会凭空闪一下、尤其在切章时才冒出来」的来源：
--    刷新回调会一直挂在 UIManager._refresh_func_stack 里，
--    直到下一次 forceRePaint（翻页 / 切章 / showBusy）才被消费。
function M:onClose()
    -- 🔴 「返回书架」途中不能收书架：阅读器 teardown 会派发 CloseWidget 到本插件，
    --    此时书架已经是**下一个界面**（不是阅读器的附属窗口），关掉它等于
    --    「点返回书架 → 书架一闪就没」。
    if not _state.returning_to_shelf and _state.active_menu then
        local menu = _state.active_menu
        _state.active_menu = nil
        H.close_widget(menu)
    end
    self:_closeDetailDialog()
    if _state.toc_menu then
        local toc = _state.toc_menu
        _state.toc_menu = nil
        H.close_widget(toc)
    end
    _state.setTocMenuOpen(false)
end

function M:onCloseWidget()
    self:onClose()
end

-- 退出应用（KOReader 退出 / 插件卸载）：先取消所有在途的异步子进程
-- （书架刷新 / 取目录 / 跳章 / 封面预下载 / 进度上传 / 检查更新 / 下载安装），再收尾界面。
--
-- ⚠️ 这一步**不能**放进 onCloseWidget：那个钩子在「从文件管理器打开一本书」时也会触发，
--    一刀切会掐掉刚发起的（如自动拉取进度）子进程。只有真正退出 KOReader 才该全清。
-- ⚠️ 顺序：先掐在途异步，**再**收尾。这里刻意**不**调 onCloseDocument ——
--    它会补发一次「最后一次进度上传」的新子进程，而那时 cancel_all 已经跑过，
--    这个新子进程反而没人管了。收尾只做界面层的事。
function M:onExit()
    -- 进程正在退出：关文档钩子可能随后触发，但此时绝不能再弹书架
    -- （否则 KOReader 退到一半又被插一层窗口）。
    _state.exiting = true
    if Async and Async.cancel_all then
        pcall(function() Async.cancel_all() end)
    end
    self:_stopProgressTimer()
    -- 🔴 还停在 pending 里的进度（含「在途但没跑完 on_done」的那些）必须落盘：
    --    进程一退，Async 的 poll 就不再跑，on_done 永不执行 ⇒ 不落盘就是静默丢。
    if _state.persistPendingProgress then
        _state.persistPendingProgress()
    end
    self:onCloseWidget()
    if self.settings and self.settings.flush then
        pcall(function() self.settings:flush() end)
    end
end

function M:onShowFanQieToc()
    if not (_state.current_book and _state.current_chapters) then
        return false
    end
    if not self:isCurrentDocFanqie() then
        return false
    end
    if not self.patches_ok then
        Patches.install()
        self.patches_ok = true
    end

    self:syncCurrentProgress()
    -- Reuse showChapterListing so the reader-side TOC also gets the
    -- persistent catalog cache and the refresh button.
    self:showChapterListing(_state.current_book)
    return true
end

function M:onShowFanQieBookshelf()
    if not (self.ui and self.ui.document) then
        self:showBookshelf()
    end
    return true
end

-- Dispatcher 动作 `return_fanqie_bookshelf` 的落点（手势 / 快捷键触发）。
function M:onReturnFanQieBookshelf()
    if not self:isCurrentDocFanqie() then
        -- 不在番茄章节里：这个动作没有意义，不要误把普通书的阅读器关掉。
        return true
    end
    self:returnToBookshelf({ force_refresh = false })
    return true
end

-- ===========================================================================
-- 返回番茄书架（阅读界面 ⇄ 书架）
-- ===========================================================================
--
-- 需求：读番茄小说时「一键回书架」，不要先退到文件管理器再点菜单。
--
-- 实现要点：
--   ① 阅读界面的「番茄小说 → 返回书架」菜单项 + 手势/快捷动作
--      `return_fanqie_bookshelf`（用户可在 KOReader 手势管理器里绑到任意手势）。
--   ② 顺序是「**先开书架，再关阅读器**」：Android 版 KOReader 关掉窗口栈里
--      最后一个窗口时会直接退出 App（`UIManager:quit()`），反过来先关阅读器
--      的话书架根本没机会显示。先 show 书架 → 栈里始终有窗口 → 再关阅读器
--      只移除它自己，App 不退出。
--   ③ 关阅读器走 `ReaderUI.instance:onClose()`（不是硬拔）：CloseDocument 会
--      正常派发，进度补传 / 加书架询问等收尾都在 onCloseDocument 里。
--   ④ 已经不在阅读界面时（比如从文件管理器菜单触发），直接开书架，
--      不做任何关闭动作。
--   ⑤ **静默刷新**（用户选择）：回书架时复用内存里的书架菜单（滚动位置、
--      排序、搜索词全部保留），数据在后台静默拉一次、回来后原地更新。
--      不弹「正在刷新书架...」，也不重建菜单 —— 重建会在墨水屏上闪一下，
--      而且刷新回调在用户已经进阅读器时会把书架重新盖上去。
--   ⑥ 书架底下垫一层文件管理器（见 _ensureShelfBackdrop 的定义处）。
function M:returnToBookshelf(opts)
    opts = opts or {}
    local ok_rui, RUI = pcall(require, "apps/reader/readerui")
    local in_reader = ok_rui and RUI and RUI.instance ~= nil
    -- 回书架一律静默刷新：不弹 loading、不重建菜单（见上方 ⑤）。
    local shelf_opts = { silent = opts.silent ~= false, force_refresh = false }

    local self_ref = self
    local function show_shelf()
        -- 书架菜单还在内存里：直接压回栈顶（滚动位置、排序、搜索关键字原样保留）。
        -- 🔴 已经在栈上时**不能**再 show 一次：UIManager:show 不查重，
        --    会往栈里插一条重复记录，之后关一次只摘掉一条，菜单永远关不干净。
        local menu = self_ref:_shelfMenuVisible(true)
        if menu then
            local shown = H and H.widget_shown and H.widget_shown(menu)
            if not shown then
                -- 阅读器即将关闭：书架要先有垫底才能压栈。
                self_ref:_ensureShelfBackdrop(true)
                local ok_show = pcall(function() UIManager:show(menu) end)
                if not ok_show then menu = nil end
            end
            if menu then
                _state.active_menu = menu
                self_ref._shelf_dismissed = false
                -- 后台静默刷新：数据回来后走 showBookList 的原地更新分支。
                -- skip_show：书架已经在屏幕上，不必再拿缓存重绘一次。
                pcall(function()
                    self_ref:showBookshelf({
                        silent = shelf_opts.silent,
                        skip_show = true,
                    })
                end)
                return true
            end
        end
        -- 没有现成书架：正常打开（缓存优先，静默后台刷新）。
        -- 此刻阅读器还开着（下一次 UI tick 才关），但 showBookshelf 是**显式调用**，
        -- 只会走「新建」，不会被后台刷新的收敛逻辑拦下。
        self_ref:_ensureShelfBackdrop(true)
        self_ref:showBookshelf({ silent = shelf_opts.silent })
        return true
    end

    if not in_reader then
        show_shelf()
        return true
    end

    -- 书架数据先就位（纯本地缓存，不阻塞）
    if type(self.ensureShelfSnapshot) == "function" then
        pcall(function() self:ensureShelfSnapshot() end)
    end

    -- 阅读器马上就要关掉：先保证书架底下还有一层窗口（见 ⑥）。
    self:_ensureShelfBackdrop(true)

    -- ⚠️ 这一步放在菜单/手势回调里是安全的（show 只是往栈上压一个窗口，
    --    没有 free 正在执行回调的控件树）；真正危险的 close 挪到下一轮事件循环。
    local ok_show, show_err = pcall(show_shelf)
    if not ok_show then
        if Log then Log.error("returnToBookshelf: show shelf failed:", tostring(show_err)) end
        return false
    end

    -- 抑制 onCloseDocument 里的「关闭阅读后回书架」（它也会开书架），
    -- 否则刚压上去的书架会被关掉重建一次（墨水屏上会闪一下）。
    _state.returning_to_shelf = true
    UIManager:scheduleIn(0, function()
        local ok2, RUI2 = pcall(require, "apps/reader/readerui")
        local inst = ok2 and RUI2 and RUI2.instance
        if inst then
            local ok_close, err = pcall(function() inst:onClose() end)
            if not ok_close and Log then
                Log.error("returnToBookshelf: close reader failed:", tostring(err))
            end
        end
        _state.returning_to_shelf = false
    end)
    return true
end


return M
