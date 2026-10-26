-- fanqie/comments/comment_actions.lua —— 从 main.lua 按原函数边界拆分。
-- 方法名与实现保持原接口；共享依赖集中在 fanqie.runtime。

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local Client = require("fanqie.client")
local CoverCache = require("fanqie.cover_cache")
local Log = require("fanqie.logger")
local Async = require("fanqie.async")
local Runtime = require("fanqie.runtime")
local _state = Runtime.state

local M = {}
local C = require("fanqie.comments.shared")

-- 段评开关已移至「设置」页面（getSettingsMenuItems 中的"段评显示"），
-- 阅读时点击「重新获取本章节」会根据开关状态决定是否带段评获取正文。

-- 显示段评列表对话框
function M:showParaReviewList()
    local reviews = _state.getCurrentParaReviews()
    if #reviews == 0 then
        self:showInfo(_("当前章节暂无段评数据"))
        return
    end
    
    -- 构建段评列表项
    local items = {}
    for i, pr in ipairs(reviews) do
        table.insert(items, {
            text = string.format("%d. %d条评论", i, pr.count or 0),
            callback = function()
                self:showParaReviewDetail(i)
            end,
        })
    end
    
    local menu = Menu:new{
        title = _("段评列表"),
        item_table = items,
        items_per_page = 20,
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            _state.active_menu = nil
        end,
    }
    _state.active_menu = menu
    UIManager:show(menu)
end

-- 显示单段段评详情（从API获取评论数据，每页 PARA_REVIEW_PAGE_SIZE 条 + cursor 分页）
-- 段评统一走官方 App commentapi 协议（ident 格式 fqapp://book_id/item_id/para_index，
-- 由 client.lua official_get_content 注入气泡时生成）。
-- opts.page：段评列表页码（缺省 1）。
-- 翻页说明：commentapi 的 cursor 只能前向翻页，已取回的页缓存在
-- self._para_pages[ident]（父进程），回翻零请求；缺页时在子进程内用
-- cursor 链顺序补拉（每页一次请求），取回后在父进程回调里合并缓存。
-- ⚠️ 缓存合并必须在父进程回调里做：子进程内的 table 改动不会传回。
-- 分页大小由 fanqie.comments.shared 提供（常量定义只在那里一份）。

function M:showParaReviewDetail(index, opts)
    opts = opts or {}
    local page = math.max(1, math.floor(tonumber(opts.page) or 1))
    local reviews = _state.getCurrentParaReviews()
    local pr = reviews[index]
    if not pr or not pr.ident then
        self:showInfo(_("段评数据无效"))
        return
    end

    -- 段评图片每小时最多自动清一次（comment_images/ 只增不减；过期图在
    -- view_image_entries / showCommentImage 里已被「当没有」处理，这里只回收磁盘）。
    if CoverCache then
        pcall(CoverCache.maybe_auto_prune_comment_images, self.settings, { self:_comment_image_dir() })
    end

    local self_ref = self
    local ident = pr.ident
    local review_index = index
    local total_reviews = #reviews
    -- 气泡上显示的服务端统计条数：列表请求失败/为空时用它兜底提示，
    -- 避免把「请求失败」显示成「共 0 条评论」（对齐 kindle-forge 前端的
    -- `if (!total) total = list.length || count` 回退）。
    local bubble_count = tonumber(pr.count) or 0

    -- 每个 ident 一份页缓存：pages[q]=该页评论列表、infos[q]=分页信息、cursors[q]=进第 q 页用的 cursor
    self._para_pages = self._para_pages or {}
    local cache = self._para_pages[ident]
    if not cache then
        cache = { pages = {}, infos = {}, cursors = { [1] = "" } }
        self._para_pages[ident] = cache
    end

    -- 翻页链已断（服务端末页）时收缩目标页到最近可达页
    local p = page - 1
    while p >= 1 and not cache.pages[p] do
        p = p - 1
    end
    if p >= 1 and cache.cursors[p + 1] == nil then
        page = p
    end

    -- 已取回的页直接渲染（回翻零网络请求）
    if cache.pages[page] then
        self_ref:_displayParaReviewDetail(review_index, total_reviews, true, {
            comments = cache.pages[page],
            info = cache.infos[page] or {},
            __page = page,
            __bubble_count = bubble_count,
            __ident = ident,
        }, nil)
        return
    end

    -- 子进程从最近的已缓存页 (p+1) 顺序补拉到目标页
    local start_page = p + 1
    local cursors_snapshot = {}
    for k, v in pairs(cache.cursors) do
        cursors_snapshot[k] = v
    end

    local function walk_pages(c)
        local fetched = {}
        local q = start_page
        while q <= page do
            -- official_get_para_review 失败时返回 nil+err（对齐 kindle-forge：
            -- 「签名不合规 → 200 空响应」「code≠0」都算失败，绝不能降级成空页）
            local pg, ferr = c:official_get_para_review(ident, {
                count = C.PARA_REVIEW_PAGE_SIZE,
                cursor = cursors_snapshot[q] or "",
            })
            if not pg then
                return nil, ferr or "段评列表获取失败"
            end
            fetched[q] = pg
            if pg.has_more and tostring(pg.cursor or "") ~= "" then
                cursors_snapshot[q + 1] = pg.cursor
            else
                break -- 服务端末页，停止补拉
            end
            q = q + 1
        end
        return fetched
    end

    -- 将段评获取（阻塞 HTTP）移到子进程，UI 线程仅轮询，不阻塞用户操作。
    self:showBusy(_("正在获取段评..."))
    if Async and Async.run then
        Async.run(function()
            local c = Client:new(self_ref.settings)
            if Log then
                Log.info("[段评] showParaReviewDetail(异步): idx=" .. tostring(review_index)
                    .. " page=" .. tostring(page) .. "/" .. tostring(start_page)
                    .. " ident=" .. tostring(ident):sub(1, 80))
            end
            local ok, fetched, ferr = pcall(walk_pages, c)
            if not ok then error(fetched or "段评获取失败", 0) end
            if not fetched then error(ferr or "段评获取失败", 0) end
            return fetched
        end, function(ok, fetched, err)
            if not ok then
                self_ref:_displayParaReviewDetail(review_index, total_reviews, false, nil, err)
                return
            end
            -- 合并子进程取回的页到父进程缓存。
            -- ⚠️ 只缓存请求成功的页：早期版本失败时把空表也写进缓存，
            -- 于是第一次失败之后每次点击都命中空缓存、永远显示「共 0 条」。
            for q, pg in pairs(fetched) do
                cache.pages[q] = pg.comments or {}
                cache.infos[q] = {
                    cursor = pg.cursor,
                    has_more = pg.has_more,
                    total = pg.total,
                }
                if pg.has_more and tostring(pg.cursor or "") ~= "" then
                    cache.cursors[q + 1] = pg.cursor
                end
            end
            -- 实际显示页：目标页取到则显示，否则回退到取到的最深页
            local display_page = page
            while display_page > 1 and not cache.pages[display_page] do
                display_page = display_page - 1
            end
            if not cache.pages[display_page] then
                self_ref:_displayParaReviewDetail(review_index, total_reviews, false, nil,
                    "段评列表返回为空")
                return
            end
            self_ref:_displayParaReviewDetail(review_index, total_reviews, true, {
                comments = cache.pages[display_page],
                info = cache.infos[display_page] or {},
                __page = display_page,
                __bubble_count = bubble_count,
                __ident = ident,
            }, nil)
        end, { poll_interval = 0.125, timeout = 60 })
    else
        -- 降级：Async 模块未加载（极端情况），同步执行
        local c = self_ref.client or Client:new(self_ref.settings)
        local ok, fetched, ferr = pcall(walk_pages, c)
        if not ok then
            self_ref:_displayParaReviewDetail(review_index, total_reviews, false, nil, fetched)
            return
        end
        if not fetched then
            self_ref:_displayParaReviewDetail(review_index, total_reviews, false, nil, ferr)
            return
        end
        for q, pg in pairs(fetched) do
            cache.pages[q] = pg.comments or {}
            cache.infos[q] = {
                cursor = pg.cursor,
                has_more = pg.has_more,
                total = pg.total,
            }
            if pg.has_more and tostring(pg.cursor or "") ~= "" then
                cache.cursors[q + 1] = pg.cursor
            end
        end
        local display_page = page
        while display_page > 1 and not cache.pages[display_page] do
            display_page = display_page - 1
        end
        if not cache.pages[display_page] then
            self_ref:_displayParaReviewDetail(review_index, total_reviews, false, nil,
                "段评列表返回为空")
            return
        end
        self_ref:_displayParaReviewDetail(review_index, total_reviews, true, {
            comments = cache.pages[display_page],
            info = cache.infos[display_page] or {},
            __page = display_page,
            __bubble_count = bubble_count,
            __ident = ident,
        }, nil)
    end
end


-- 显示段评详情弹窗（纯 UI 渲染，不做网络请求）

-- 段评链接由 patches/core.lua 转成事件，再交给这里处理。
function M:onFanQieParaReview(idx)
    if not self:isCurrentDocFanqie() then return end
    if not idx then return end
    if _state.isChapterNavigating() then
        if Log then Log.debug("[段评] onFanQieParaReview: 章节切换中，跳过 idx=" .. tostring(idx)) end
        return true
    end
    if Log then Log.info("[段评] onFanQieParaReview: idx=" .. tostring(idx)) end
    self:showParaReviewDetail(idx)
    return true
end

return M
