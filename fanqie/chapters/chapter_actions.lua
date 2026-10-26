-- fanqie/chapters/chapter_actions.lua —— 从 main.lua 按原函数边界拆分。
-- 方法名与实现保持原接口；共享依赖集中在 fanqie.runtime。

local function safe_require(name)
    local ok, module = pcall(require, name)
    if not ok then return nil end
    return module
end

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Event = require("ui/event")
local Content = require("fanqie.content")
local H = require("fanqie.helper")
local Log = require("fanqie.logger")
local Async = require("fanqie.async")
local Runtime = require("fanqie.runtime")
local _state = Runtime.state
local display_error = Runtime.display_error
local log_error = Runtime.log_error
local getCachedChapters = Runtime.getCachedChapters
local getCurrentChapterIndex = Runtime.getCurrentChapterIndex
local make_page_heartbeat = Runtime.make_page_heartbeat

local M = {}

-- ===========================================================================
-- Chapter listing
-- ===========================================================================

function M:showChapterListing(book, opts)
    opts = opts or {}
    local force_refresh = opts.force_refresh == true
    -- remember_page: keep the user on the same page after a refresh
    local remember_page = opts.remember_page

    -- 构建并显示目录菜单（缓存命中与异步获取共用）
    local function display_chapters(chapters)
        if not chapters or #chapters == 0 then
            self:showInfo(_("未获取到章节"))
            return
        end

        _state.current_book = book
        _state.current_chapters = chapters

        -- 刷新内存缓存：预下载可能已更新文件但内存缓存未同步，
        -- 强制重新从文件加载确保目录对号准确
        _state.invalidateChapterIndexCache(book.book_id)
        local cached = Content.load_cache_index(self.settings, book.book_id)
        local current_idx = getCurrentChapterIndex()

        -- current_chapter_index 已在切章时正确更新，优先使用。
        -- 仅当 current_chapter_index 无效（首次打开/未设置）时，
        -- 才用 book.item_id（书架记录的上次阅读章节）回退定位。
        if (not current_idx or current_idx <= 0) and book.item_id then
            for i, chapter in ipairs(chapters) do
                if tostring(chapter.itemId) == tostring(book.item_id) then
                    current_idx = i
                    break
                end
            end
        end

        local items = {}
        local cached_map = {}
        if cached then
            for item_id, _ in pairs(cached) do
                cached_map[item_id] = true
            end
        end

        for i, chapter in ipairs(chapters) do
            local title = chapter.title or ("Chapter " .. tostring(i))
            local prefix = ""
            if i == current_idx then
                prefix = "▶ "
            elseif cached_map[tostring(chapter.itemId)] then
                prefix = "✓ "
            end
            table.insert(items, {
                text = prefix .. title,
                callback = function()
                    -- 先关闭目录菜单，避免切章时菜单闪现
                    if _state.active_menu then
                        UIManager:close(_state.active_menu)
                        _state.active_menu = nil
                    end
                    self:openChapter(book, chapters, i)
                end,
            })
        end

        local items_per_page = 12
        local initial_page = remember_page or 1

        if not remember_page and current_idx > 0 then
            items.current = current_idx
            initial_page = math.ceil(current_idx / items_per_page)
        end

        local plugin = self
        -- 🔴 必须先单独声明再赋值。`local chapter_menu = Menu:new{...}` 是**单条语句**，
        -- 其 local 作用域从语句*之后*才开始，因此 close_callback 闭包里引用的
        -- chapter_menu 会解析到全局 nil：`_state.active_menu == chapter_menu`
        -- 恒不成立（等于拿菜单去和 nil 比），关闭目录后 active_menu 永不清空。
        local chapter_menu
        chapter_menu = Menu:new{
            title = string.format("%s - 目录", book.title or book.book_id),
            item_table = items,
            items_per_page = items_per_page,
            is_borderless = true,
            is_popout = false,
            title_bar_left_icon = "appbar.menu",
            close_callback = function()
                if _state.active_menu == chapter_menu then
                    _state.active_menu = nil
                end
            end,
        }

        -- Wire up the title-bar left icon to open a small action menu.
        -- This icon is visible on every page of the chapter list, so the user
        -- can refresh from wherever they currently are.
        chapter_menu.onLeftButtonTap = function()
            local current_page = chapter_menu.page or 1
            local ButtonDialog = require("ui/widget/buttondialog")
            local action_dialog
            action_dialog = ButtonDialog:new{
                title = _("目录操作"),
                title_align = "center",
                buttons = {
                    {{
                        text = _("刷新目录"),
                        callback = function()
                            UIManager:close(action_dialog)
                            UIManager:close(chapter_menu)
                            _state.active_menu = nil
                            -- Re-open and stay on the same page after refresh
                            plugin:showChapterListing(book, {
                                force_refresh = true,
                                remember_page = current_page,
                            })
                        end,
                    }},
                    {{
                        text = _("关闭"),
                        callback = function()
                            UIManager:close(action_dialog)
                        end,
                    }},
                },
            }
            UIManager:show(action_dialog)
        end

        if initial_page > 1 then
            chapter_menu:onGotoPage(initial_page)
        end

        _state.active_menu = chapter_menu
        UIManager:show(chapter_menu)

        if force_refresh and not opts.silent then
            self:showInfo(_("目录已刷新"))
        end
    end

    -- Try persistent catalog cache first (so we don't hit the network every time)
    local chapters = nil
    if not force_refresh then
        chapters = Content.load_catalog_cache(self.settings, book.book_id)
        if chapters and #chapters > 0 then
            Log.debug("showChapterListing: using cached catalog, count =", #chapters)
        else
            chapters = nil
        end
    end

    -- 缓存命中：直接显示，不走网络
    if chapters and #chapters > 0 then
        display_chapters(chapters)
        return
    end

    -- 无缓存或强制刷新：子进程获取目录，UI 线程保持响应（不再卡顿）
    if not self:checkNetwork() then
        -- force_refresh 无网时回退到旧缓存
        if force_refresh then
            local cached = Content.load_catalog_cache(self.settings, book.book_id)
            if cached and #cached > 0 then
                display_chapters(cached)
                self:showInfo(_("无网络，显示缓存目录"))
                return
            end
        end
        return
    end
    self:showBusy(_("正在获取目录..."))
    local client = self.client
    local settings = self.settings
    local book_id = book.book_id
    Async.run(function()
        -- 子进程内执行 HTTP 目录获取
        local b = { book_id = book_id }
        return Content.fetch_catalog(client, b)
    end, function(ok, result, err)
        self:closeBusy()
        if not ok or type(result) ~= "table" then
            -- 获取失败：回退到旧缓存，不删除任何数据
            if force_refresh then
                local cached = Content.load_catalog_cache(settings, book.book_id)
                if cached and #cached > 0 then
                    display_chapters(cached)
                    self:showInfo(_("刷新失败，显示缓存目录"))
                    return
                end
            end
            self:showError(T(_("获取目录失败:\n%1"), display_error(err or result)))
            return
        end
        local fetched = result
        if #fetched == 0 then
            -- 空结果可能是 cookie 过期，回退到旧缓存
            if force_refresh then
                local cached = Content.load_catalog_cache(settings, book.book_id)
                if cached and #cached > 0 then
                    display_chapters(cached)
                    self:showInfo(_("获取数据为空，显示缓存目录"))
                    return
                end
            end
            self:showInfo(_("未获取到章节"))
            return
        end

        -- 获取成功：覆盖旧缓存
        Content.save_catalog_cache(settings, book_id, fetched)
        -- 同时更新内存缓存
        _state.setDirectoryCache(book_id, fetched)

        display_chapters(fetched)
    end, { poll_interval = 0.3, timeout = 60 })
end

function M:showJumpToChapter(book, chapters)
    local InputDialog = require("ui/widget/inputdialog")
    local total = #chapters

    local dialog
    dialog = InputDialog:new{
        title = _("跳转到章节"),
        input = tostring(getCurrentChapterIndex() > 0 and getCurrentChapterIndex() or 1),
        input_hint = string.format("(1-%d)", total),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("跳转"),
                    is_enter_default = true,
                    callback = function()
                        local input = dialog:getInputText()
                        local idx = tonumber(input)
                        if idx and idx >= 1 and idx <= total then
                            UIManager:close(dialog)
                            self:openChapter(book, chapters, math.floor(idx))
                        else
                            UIManager:show(InfoMessage:new{
                                text = T(_("请输入 1 到 %1 之间的数字"), total),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M:get_chapters(book_id)
    local book = { book_id = book_id }
    return Content.fetch_catalog(self.client, book)
end

-- ===========================================================================
-- Chapter reading & auto-jump next chapter
-- ===========================================================================

--- 章节下载的**心跳文件**路径（每本书一个，Async 结束时自动删掉）。
---
--- 为什么需要：图集/漫画（`book_type == 1`）一章的正文就是几十张整页大图
--- （实测《未知生物大百科》：单章 22~49 页、每页 1440×2559 约 400 KB），
--- 整章下完要 1~5 分钟。而 `Async.run` 的 `timeout` 到点会
--- `terminateSubProcess` **杀掉子进程** ⇒ 用户看到「下载超时」，已下好的几十页全丢。
--- 子进程每下完一张就把「已下载/总数」写进这个文件，父进程据此续期
--- （fanqie/async.lua 的 `opts.heartbeat`）——「只要还在下载就不算超时」，
--- 而真正卡死（长时间一张都没落盘）仍然会被掐掉。
function M:_downloadHeartbeatPath(book)
    local dir = Content.book_cache_dir(self.settings, book.book_id)
    H.make_dir(dir)   -- 心跳可能是本章**第一个**写盘的操作
    return H.join_path(dir, "._dlbeat")
end

function M:navigateToChapter(book, chapters, chapter_index, opts)
    opts = opts or {}
    local chapter = chapters[chapter_index]
    if not chapter then
        self:showInfo(_("章节不存在"))
        return false
    end

    -- 标记章节切换中：防止段评异步回调在切章后弹窗闪现
    _state.setChapterNavigating(true)

    if _state.is_downloading then
        -- 正在下载其它章节：给用户明确提示，而不是静默失败
        _state.setChapterNavigating(false)
        self:showInfo(_("正在下载中，请稍候再试"))
        return false
    end

    _state.current_book = book
    _state.current_chapters = chapters

    -- 从全局状态获取段评开关，传递 review=true 给内容获取
    -- skip_cache_index=true：子进程不写共享索引，由父进程统一持久化
    local review_enabled = _state.isReviewEnabled()
    -- heartbeat_path：下载心跳（见 fanqie/async.lua 的 opts.heartbeat）。
    -- 图集/漫画一章几十页大图，整章下载要几分钟 —— 有心跳才不会因为「总时长」
    -- 被 Async 掐掉、白丢已经下好的几十页。
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

    local item_id = tostring(chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    -- 索引命中也要按结构版本/整段可点开关就地升级（见 Content.ensure_chapter_upgraded）
    local existing_path = Content.ensure_chapter_upgraded(self.settings, cached_chapters[item_id])

    -- 已缓存正文直接使用：段评数据缺失不触发重下（有些章节本就无段评）。
    -- 想要段评的用户可通过「重新获取本章节」手动重下（按当前段评开关决定是否带段评）。

    -- If not found in cache index, try to find file directly from filesystem
    if not existing_path or not H.file_exists(existing_path) then
        local found_path = Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found_path then
            -- Update cache index with found file
            cached_chapters[item_id] = found_path
            Content.save_cache_index(self.settings, book.book_id, cached_chapters)
            existing_path = found_path
            if Log then Log.info("found cached chapter in filesystem:", item_id) end
        end
    end

    if existing_path and H.file_exists(existing_path) then
        _state.current_chapter_index = chapter_index
        _state.pre_download_triggered = false
        -- 加载段评数据到全局状态
        if review_enabled then
            local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
            _state.setCurrentParaReviews(reviews)
        end
        self:showReaderUI(existing_path, chapter)
        if opts.after_navigate then
            UIManager:scheduleIn(1.0, opts.after_navigate)
        end
        return true
    end

    _state.is_downloading = true
    -- 图集/漫画（book_type=1）一章就是几十张整页大图，光下载就得几分钟 ——
    -- 文案里先说一声，免得用户当成卡死。真卡死仍会被 Async 的停滞超时掐掉
    -- （只要还有图在落盘，心跳就会给超时续期，见 fanqie/async.lua）。
    -- 🔴 用 tonumber：书城/书架接口给的 book_type 是**字符串** "1"（实测）。
    local comic = tonumber(book.book_type) == 1
    if comic then
        self:showBusy(T(_("正在下载图集: %1\n（整章为多页大图，请稍候）"), chapter.title or ""))
    else
        self:showBusy(T(_("正在下载: %1"), chapter.title or ""))
    end

    local b = { book_id = book.book_id, title = book.title, author = book.author }
    local client = self.client
    local settings = self.settings
    -- 段评获取与章节正文下载一起在子进程执行，UI 线程仅轮询，不再卡顿
    Async.run(function()
        local path, _ch, para_reviews, rate_info = Content.fetch_chapter_html(client, settings, b, chapter, fetch_opts)
        return { path = path, para_reviews = para_reviews, rate_info = rate_info }
    end, function(ok, result, err)
        self:closeBusy()

        if not ok or type(result) ~= "table" or not result.path then
            Log.error("navigateToChapter download failed:", tostring(err or result))
            _state.is_downloading = false
            _state.setChapterNavigating(false)
            self:showError(T(_(opts.error_message or "下载章节失败:\n%1"), display_error(err or result)))
            return
        end


        local path = result.path
        local para_reviews = result.para_reviews
        -- 合并子进程记录的限流时间戳（子进程退出即丢失）
        if result.rate_info then
            local ok_sm, SM = pcall(require, "fanqie.sources")
            if ok_sm and SM and SM.merge_rate_limit_timestamps then
                SM.merge_rate_limit_timestamps(result.rate_info)
            end
        end

        local cc = getCachedChapters(self, book)
        cc[item_id] = path
        -- 父进程统一持久化完整索引
        Content.save_cache_index(settings, book.book_id, cc)

        -- 存储段评数据到全局状态
        if review_enabled and para_reviews then
            _state.setCurrentParaReviews(para_reviews)
        end

        _state.current_chapter_index = chapter_index
        _state.pre_download_triggered = false
        _state.is_downloading = false
        self:showReaderUI(path, chapter)

        if opts.after_navigate then
            UIManager:scheduleIn(1.0, opts.after_navigate)
        end
    end, { delay = 0.1, poll_interval = 0.2,
           -- 停滞上限（有心跳时掐的不是总时长，见 fanqie/async.lua）：
           -- 图集单页 ~570KB，慢网下单次请求就可能逼近 socket 超时，给 180s 余量。
           timeout = comic and 180 or 60,
           heartbeat = fetch_opts.heartbeat_path,
           -- 「正在下载图集…（第 N/M 页）」：没有它用户分不清在下还是卡死
           on_heartbeat = make_page_heartbeat(self, chapter, comic) })

    return true
end

function M:openChapter(book, chapters, chapter_index)
    return self:navigateToChapter(book, chapters, chapter_index, {
        error_message = "下载章节失败:\n%1",
    })
end

-- 向「接管 ReaderUI 生命周期的书壳插件」声明一次计划内的文档切换。
--
-- 背景：miuread 这类书壳插件会把**任何**打开的文档（包括番茄章节 HTML）收编进
-- 自己的会话，然后在 `onCloseDocument` 里区分三种关闭：它自己发起的 / 计划内的
-- 文档切换（`HOME_SESSION.opening_file` 已指向新文档）/ **来历不明的 ReaderUI
-- 消失**。第三种会触发它的「重建看门狗」（0.22s 起步轮询，2.4~18s 超时），
-- 超时后走「读者已关闭」收尾——回主页、装全屏过渡 Guard（`stop_events_propagation`
-- 且在 `ReaderUI.instance.document` 为空的窗口期吞掉一切输入）。慢设备上 crengine
-- 加载下一章的耗时很容易越过看门狗预算，于是「章末自动下一章」的关旧开新被它的
-- 回主页机制抢跑/吞掉，表现为「跳下一章失败」。
--
-- 修法：miuread 把会话状态故意放在全局 `_G.__MIUREAD_HOME_SESSION`（它的 Home
-- 实例与 Reader 实例就靠这个共享），我们在 showReader 前**声明**切换目标，
-- 它的 `onCloseDocument` 就会走「计划内文档切换」分支：干净收尾旧实例，
-- 不启看门狗、不回主页。表不存在 = 没装书壳插件，整段空转。
--
-- ⚠️ 只做防御性 pcall + 字段级写入：对方改字段名/改实现时这里静默降级，
-- 绝不能反过来被它拖崩。`opening_kind` 置 ""（番茄章节不是它的 local/weread 书）。
function M:_announceDocSwitchToShell(path)
    pcall(function()
        local session = rawget(_G, "__MIUREAD_HOME_SESSION")
        if type(session) ~= "table" then return end
        session.opening_file = path
        session.opening_at = os.time()
        session.opening_kind = ""
        session.opening_book_id = ""
    end)
end

-- 打开失败/被取消时撤回声明，避免残留的 opening_file 把下一次无关关闭
-- 误判成「计划内切换」（那样书壳插件会跳过本该做的收尾）。
function M:_retractDocSwitchAnnouncement(path)
    pcall(function()
        local session = rawget(_G, "__MIUREAD_HOME_SESSION")
        if type(session) ~= "table" then return end
        if session.opening_file == path then
            session.opening_file = nil
            session.opening_at = 0
        end
    end)
end

function M:showReaderUI(path, chapter)
    local ReaderUI = require("apps/reader/readerui")
    self:_announceDocSwitchToShell(path)

    -- 🔴 打开前的最后一道升级闸门：所有章节打开路径（首次打开 / 上一章 / 下一章 /
    --    预下载命中 / 文件系统兜底）最终都汇集到这里，在这里升级能保证不遗漏。
    --    上面几处 ensure_chapter_upgraded 仍然保留：它们会把升级后的状态带给各自的
    --    后续逻辑；这里的调用是幂等的（已升级过 → 一个字节都不动）。
    path = Content.ensure_chapter_upgraded(self.settings, path)

    -- 章节切换已完成（新文档即将加载），清除导航标志
    _state.setChapterNavigating(false)

    -- 🔴 切文档窗口标记（见 fanqie/state.lua 的 switching_document 说明）。
    --    `ReaderUI:showReader` 的 doShowReader 是「先关旧实例（派发 CloseDocument）
    --    → 下一个 tick 才建新实例」，中间 `ReaderUI.instance == nil`。
    --    不显式标记，onCloseDocument 的「关闭后回书架」会把切章当成真退出，
    --    把书架盖到新章上（实测：读完一章不跳下一章，而是弹回书架）。
    --    由新文档的 ReaderReady 清除；打开失败时在本函数里清。
    _state.switching_document = true
    _state.switching_document_token = (_state.switching_document_token or 0) + 1
    local switch_token = _state.switching_document_token


    local ok, err = pcall(function()
        -- 不用 switchDocument（其内部先 onClose 再 showReader，中间 forceRePaint 会闪现书架）
        -- 直接用 showReader：doShowReader 在 nextTick 中关闭旧实例并打开新实例，无闪现
        if not ReaderUI.instance then
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
        end
        ReaderUI:showReader(path, nil, true)  -- seamless=true 隐藏"打开文件"提示
    end)
    if not ok then
        self:_retractDocSwitchAnnouncement(path)
        _state.chapter_switch_pending = false
        if _state.switching_document_token == switch_token then
            _state.switching_document = false
        end
        Log.error("showReaderUI failed:", log_error(err))
        self:showError(T(_("打开文档失败:\n%1"), display_error(err)))
        return
    end
    _state.current_document_path = path
    _state.document_opened = true
    -- 兜底：正常情况下新文档的 ReaderReady 会清掉 switching_document（那是权威信号）。
    -- 但 showReader 可能因为「文件不存在 / 没有可用引擎」只在栈上弹个 InfoMessage
    -- 就返回（见 readerui.lua showReader 开头的 lfs.attributes 检查），根本不会
    -- 广播 ReaderReady —— 标志若一直挂着，之后每次真退出都会被当成「切章」，
    -- 「关闭阅读后回书架」就永久失效。给一个足够宽的兜底窗口：
    -- 打开一本章节最多几秒，10 秒还没就绪就认为这次切换失败了。
    UIManager:scheduleIn(10, function()
        -- 代际不一致 = 这 10 秒里又发生了一次切换，别动新一轮的标志。
        if _state.switching_document and _state.switching_document_token == switch_token then
            _state.switching_document = false
            if Log then Log.warn("[FanQie] switching_document timeout, cleared") end
        end
    end)
    
    if _state.current_book then
        UIManager:scheduleIn(1.0, function()
            if _state.current_book then
                getCachedChapters(self, _state.current_book)
                -- 上次退出时没传完的进度（pending 落过盘）在这里补一发；
                -- 否则要等用户翻到章末 / 关文档才会重试。没有待传项时是空转。
                self:retryPendingProgress()
            end
        end)
    end
end

-- Reload current chapter: delete cached file and re-download

return M
