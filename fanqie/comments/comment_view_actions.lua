-- fanqie/comments/comment_view_actions.lua —— 从 main.lua 按原函数边界拆分。
-- 方法名与实现保持原接口；共享依赖集中在 fanqie.runtime。

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template

local UIManager = require("ui/uimanager")
local TextViewer = require("ui/widget/textviewer")
local ImageViewer = require("ui/widget/imageviewer")
local CommentView = require("fanqie.comment_view")
local Client = require("fanqie.client")
local ImgSize = require("fanqie.img_size")
local H = require("fanqie.helper")
local Log = require("fanqie.logger")
local Async = require("fanqie.async")
local CoverCache = require("fanqie.cover_cache")
local Runtime = require("fanqie.runtime")
local _state = Runtime.state

local M = {}
local C = require("fanqie.comments.shared")

function M:_displayParaReviewDetail(index, total_reviews, ok, result, err)
    -- 章节切换中：异步段评获取完成时可能已进入新章节，丢弃过期的段评弹窗
    if _state.isChapterNavigating() then
        if Log then Log.debug("[段评] _displayParaReviewDetail: 章节切换中，丢弃段评弹窗") end
        self:closeBusy()
        return
    end
    if not ok then
        if Log then Log.error("[段评] 获取失败:", tostring(err or result)) end
        self:closeBusy()
        self:showInfo(_("段评获取失败: ") .. tostring(err or result))
        return
    end

    -- 评论条目已在子进程由 Comments.flatten_comment 归一（对齐 kindle-forge
    -- api.get_para_comments 的 {'comments':[扁平]}），这里不再解析嵌套结构。
    local comments = (type(result) == "table" and type(result.comments) == "table")
        and result.comments or {}
    local info = (type(result) == "table" and type(result.info) == "table")
        and result.info or {}

    if Log then
        local t = tonumber(info.total) or 0
        Log.info("[段评] 本页返回: comments=" .. #comments .. " total=" .. tostring(t))
    end

    local total = tonumber(info.total) or 0
    if total <= 0 then total = #comments end
    -- 服务端 total 缺失时用气泡上的统计条数兜底
    if total <= 0 then total = tonumber(result and result.__bubble_count) or 0 end

    self:closeBusy()

    if #comments == 0 then
        -- 请求成功但服务端没给条目：把气泡上的统计条数一起显示，
        -- 便于区分「本段确实没评论」与「服务端返回为空」。
        local bubble_count = tonumber(result and result.__bubble_count) or 0
        if bubble_count > 0 then
            self:showInfo(T(_("本条段评共 %1 条，服务端未返回内容，请稍后重试"),
                tostring(bubble_count)))
        else
            self:showInfo(_("本段暂无可显示的段评"))
        end
        return
    end

    -- 渲染所需状态存下来：回复展开/收起按钮只改这里，再原地重排
    self._para_view_state = {
        index = index,
        total_reviews = total_reviews,
        ident = result and result.__ident or nil,
        comments = comments,
        info = info,
        page = tonumber(result and result.__page) or 1,
        total = total,
    }
    self:_renderParaReviewView(false)
end

-- 重新渲染当前段评弹窗。
-- in_place=true 走 TextViewer:reinit()（保留滚动位置）；false 时新建窗口
-- （翻页/换段后应当从头看起）。
-- ---------------------------------------------------------------- 新段评视图

-- 段评图片本地缓存路径（与 showCommentImage 同一套命名，缓存互通）。
-- ⚠️ 图片 URL 带签名、不可改写（实测改后缀/去 query/换 host 全 403），只能原样下载。
-- 🔴 后缀必须落在 `DocumentRegistry.image_ext` 白名单里（jpg/jpeg/png/gif/webp/tif/svg）：
--    `ImageWidget:_loadfile()` 第一句是 `DocumentRegistry:isImageFile(self.file)`，而它
--    是**按后缀**判的（`image_ext[getSuffix(file)]`），不在白名单里就直接
--    `error("Image file type not supported.")` ⇒ 图**根本画不出来**，整条评论只剩文字。
--    番茄段评图 URL 常以 `~tplv-xxx:800:0:0` 这类**无后缀**形式结尾
--    （`Comments.image_ext` 返回 nil），以前 `im.format or "img"` 就落成 `.img` ⇒
--    所有这类图都被默默吞掉。
--    注：真实内容类型由 `RenderImage:renderImageData` 按**文件头**嗅探
--    （RIFF→libwebp、0xFFD8→jpeg、其余交 MuPDF），所以后缀只是「过闸门」用的，
--    猜成 jpg 也不会把 webp 内容解错。
local IMAGE_EXT_OK = {
    jpg = true, jpeg = true, png = true, gif = true, webp = true, tif = true, tiff = true,
}

--- 缓存文件名后缀：认识的原样用，不认识的一律落到 `jpg`（理由见上面白名单注释）。
local function safe_image_ext(im)
    local fmt = type(im) == "table" and tostring(im.format or "") or ""
    fmt = fmt:lower()
    if IMAGE_EXT_OK[fmt] then return fmt end
    return "jpg"
end

local function para_image_path(plugin, owner, owner_no, img_no, im)
    local dir = plugin:_comment_image_dir()
    local cid = (owner.comment_id and tostring(owner.comment_id)) or tostring(owner_no)
    return H.join_path(dir, "c_" .. cid .. "_" .. tostring(img_no)
        .. "." .. safe_image_ext(im))
end

--- 这张图之前下载失败过吗。失败记录挂在当前段评状态上（换段/重开自动失效）。
local function para_image_failed(plugin, path)
    local st = plugin and plugin._para_view_state
    local fails = st and st._image_failures
    return (type(fails) == "table" and fails[path] == true) or false
end

--- 这张段评图缓存还能用吗：**存在之外还要新鲜**。
--- 段评图（c_<cid>_<n>）落盘后曾永不失效，目录只增不减；有效期见 settings 的
--- `cache.comment_image_ttl_minutes`（0 = 永久，默认 60 分钟）。过期的图在
--- 命中前**当没有**处理：预取会重下并覆盖同名文件（mtime 随之刷新）。
local function comment_image_fresh(plugin, path)
    if not CoverCache then return true end
    local s = plugin and plugin.settings
    if not (s and type(s.get_comment_image_ttl_minutes) == "function") then return true end
    return CoverCache.is_fresh_minutes(path, s:get_comment_image_ttl_minutes())
end

-- 渲染块的图片条目：已下载→内嵌；未下载→「加载中」占位；不可显示→显式说明。
-- 同时返回缺失清单（供后台串行下载），项 { owner=, img_no=, im=, path= }。
-- 图片条目（视图用）。`allow_tap` 为真时给**可显示的图**挂上点击载荷 ——
-- 点图开全屏（落点是 showCommentImage）。
--
-- ⚠️ 只有**顶层评论**能开图：showCommentImage 用 `state.comments[comment_no]`
--    取原始记录，而回复节点（build_reply_blocks）的 owner_no 是 comment_id 字符串，
--    落不到同一张表上。所以回复里的图**不给 tap**（与回退路径只给顶层图按钮一致）。
--    `tap` 载荷 = { no = 顶层评论序号, img = 图片在 comment_images() 里的下标 }。
local function view_image_entries(plugin, owner, owner_no, allow_tap)
    local entries, missing = {}, {}
    local list = C.comment_images(owner)
    for k, im in ipairs(list) do
        if not im.displayable then
            entries[#entries + 1] = { note = T(_("（%1 图片，本设备无法显示）"),
                string.upper(tostring(im.format or "HEIC"))) }
        else
            local tap = allow_tap and { no = owner_no, img = k } or nil
            local path = para_image_path(plugin, owner, owner_no, k, im)
            -- 过期图当没有：落进 missing，预取会重下并覆盖同名文件
            if H.file_exists(path) and comment_image_fresh(plugin, path) then
                -- 渲染尺寸用**文件真实宽高**：服务端的 width/height 经常缺
                -- （`~tplv…:300:0` 模板图就没有）或与转码产物对不上，比例一错
                -- 渲染端只能正方形兜底 ⇒ 图周围全是留白（用户报的问题）。
                -- 读文件头 O(1)，结果按路径记忆（见 fanqie/img_size.lua）；
                -- 探测失败回退服务端字段。
                local w, h = im.width, im.height
                if ImgSize then
                    local rw, rh = ImgSize.probe(path)
                    if rw and rh then w, h = rw, rh end
                end
                entries[#entries + 1] = { path = path, w = w, h = h,
                                          img_no = k, tap = tap }
            else
                -- 「正在后台加载…」这一行也可点：点它当场下载并打开
                -- （不必等预取；预取完成后会被上面的 path 分支替换掉）
                -- 失败过的那张明说「加载失败」：永远停在「正在加载」既不告诉用户出了
                -- 什么事、也没法判断还能不能好，是这类异步 UI 最常见的坑。
                local note
                if para_image_failed(plugin, path) then
                    note = T(_("（图%1：加载失败，点这行重试）"), tostring(k))
                else
                    note = T(_("（图%1：正在后台加载…）"), tostring(k))
                end
                entries[#entries + 1] = { note = note, img_no = k, tap = tap }
                missing[#missing + 1] = { owner = owner, img_no = k, im = im, path = path }
            end
        end
    end
    return entries, missing
end

-- 回复树 → 视图块（头行文案与 append_reply_lines 口径一致）。
-- 返回 blocks, missing（缺失图片清单，供后台下载）。
local function build_reply_blocks(plugin, roots)
    local out, missing_all = {}, {}
    local function walk(list)
        for _i, node in ipairs(list or {}) do
            local to = ""
            if node.reply_to_user_name and node.reply_to_user_name ~= node.user_name then
                to = T(_(" 回复 %1"), tostring(node.reply_to_user_name))
            end
            local head = T(_("↳ %1%2%3 · ♥%4"), tostring(node.user_name or _("匿名")),
                C.comment_titles_text(node), to,
                tonumber(node.digg_count) or 0)
            local ts = C.fmt_comment_time(node.create_time)
            if ts ~= "" then head = head .. "  " .. ts end
            local imgs, missing = view_image_entries(plugin, node, node.comment_id)
            for _k, m in ipairs(missing) do missing_all[#missing_all + 1] = m end
            out[#out + 1] = {
                head = head,
                text = tostring(node.text or ""),
                images = imgs,
            }
            if node.children and #node.children > 0 then
                walk(node.children)
            end
        end
    end
    walk(roots)
    return out, missing_all
end

-- 拉取某条评论的回复并合入缓存（**不渲染**）。on_done(ok) 在父进程回调。
-- 与 showParaReviewReplies 共用同一套游标/上限逻辑；签名不合规时服务端回
-- 200 空响应，client 层转成 (nil, err)，这里必须报错而不是退化成「没回复」。
function M:_fetchParaReplies(index, comment_no, on_done)
    local state = self._para_view_state
    if not state or state.index ~= index then
        self:showInfo(_("段评数据已失效，请重新打开"))
        if on_done then on_done(false) end
        return
    end
    local comment = state.comments[comment_no]
    local cid = comment and comment.comment_id and tostring(comment.comment_id) or nil
    if not cid then
        self:showInfo(_("段评数据无效"))
        if on_done then on_done(false) end
        return
    end
    local cache = state.ident and self._para_pages and self._para_pages[state.ident] or nil
    if not cache then
        self:showInfo(_("段评数据已失效，请重新打开"))
        if on_done then on_done(false) end
        return
    end
    cache.expanded = cache.expanded or {}
    cache.replies = cache.replies or {}
    local rs = cache.replies[cid]
    if not rs then
        rs = { flat = {}, pages = 0, cursor = "", has_more = true, total = 0 }
        cache.replies[cid] = rs
    end
    local remain = C.PARA_REPLY_MAX_PAGES - (rs.pages or 0)
    if remain <= 0 then
        self:showInfo(_("已达到单次加载上限"))
        if on_done then on_done(false) end
        return
    end
    local cursor = (rs.pages or 0) > 0 and rs.cursor or ""
    local self_ref = self
    if Log then
        Log.info("[段评] 获取回复: idx=" .. tostring(index) .. " comment=" .. cid
            .. " cursor=" .. tostring(cursor) .. " 可拉页数=" .. tostring(remain))
    end
    self:showBusy(_("正在获取回复..."))
    if not (Async and Async.run) then
        self:closeBusy()
        self:showInfo(_("异步模块不可用，无法获取回复"))
        if on_done then on_done(false) end
        return
    end
    Async.run(function()
        local c = Client:new(self_ref.settings)
        local flat, cur, has_more, total, pages = {}, cursor, true, 0, 0
        while pages < remain do
            local pg, ferr = c:official_get_para_replies(cid, {
                count = C.PARA_REPLY_PAGE_SIZE,
                cursor = cur,
            })
            -- 子进程里只有 error() 能把失败原因带回父进程
            if not pg then
                error(ferr or "段评回复获取失败", 0)
            end
            for _i, r in ipairs(pg.replies or {}) do
                flat[#flat + 1] = r
            end
            total = tonumber(pg.total) or total
            pages = pages + 1
            local nxt = tostring(pg.cursor or "")
            if pg.has_more and nxt ~= "" and nxt ~= cur then
                cur = nxt
            else
                has_more = false
                break
            end
        end
        return {
            flat = flat,
            cursor = cur,
            has_more = has_more,
            total = total,
            pages = pages,
        }
    end, function(ok, res, ferr)
        self_ref:closeBusy()
        if not ok or type(res) ~= "table" then
            if Log then Log.error("[段评] 回复获取失败:", tostring(ferr or res)) end
            self_ref:showInfo(T(_("回复获取失败: %1"), tostring(ferr or res)))
            if on_done then on_done(false) end
            return
        end
        -- ⚠️ 合并必须在父进程做：子进程里的 table 改动不会回传
        local flat_before = #rs.flat
        for _i, r in ipairs(res.flat or {}) do
            rs.flat[#rs.flat + 1] = r
        end
        rs.pages = (rs.pages or 0) + (tonumber(res.pages) or 0)
        rs.cursor = tostring(res.cursor or "")
        rs.has_more = res.has_more == true
        rs.total = tonumber(res.total) or rs.total
        -- ⚠️ 「空成功」闸门（2026-10-17，排查「展开回复后空白」）：client 层已挡
        --    total>0 的空列表，这里再挡 total 一并被抹成 0 的那一种 —— 评论自己
        --    明明挂着 reply_count>0，首页却 0 条。放行的后果不只是这一次空白：
        --    pages 记成 1 后，「纯展开零请求」分支（rs.pages>0 直接复用缓存）会把
        --    空结果**粘死**，收起再展开永远不再发请求 ⇒ 必须整体回滚（含裁掉本次
        --    并进的空段、清零 pages/cursor/total），让下一次点开真的重新拉第一页。
        local want = tonumber(comment.reply_count) or 0
        if #rs.flat == 0 and want > 0 then
            for _i = #rs.flat, flat_before + 1, -1 do
                rs.flat[_i] = nil
            end
            rs.pages = 0
            rs.cursor = ""
            rs.has_more = true
            rs.total = 0
            if Log then
                Log.warn("[段评] 回复列表为空但评论挂着回复数: cid=" .. tostring(cid)
                    .. " reply_count=" .. tostring(want)
                    .. " resp_pages=" .. tostring(res.pages)
                    .. " resp_total=" .. tostring(res.total))
            end
            self_ref:showInfo(_("回复列表返回为空（可能被风控），请稍后重试"))
            if on_done then on_done(false) end
            return
        end
        if Log then
            Log.info("[段评] 回复合并: cid=" .. tostring(cid)
                .. " flat=" .. tostring(#rs.flat)
                .. " total=" .. tostring(rs.total)
                .. " pages=" .. tostring(rs.pages))
        end
        if on_done then on_done(true) end
    end, { poll_interval = 0.125, timeout = 60 })
end

-- 「回复」按钮（cycling）：有收起的→全部展开；都展开但有更多→续拉；
-- 全部加载完→全部收起。整条链路只占**一个**固定按钮。
-- 后台串行下载本页缺失的段评图片；每张完成即 refresh（逐张浮现）。
function M:_prefetchParaImages(index)
    local state = self._para_view_state
    if not state or state.index ~= index then return end
    if state._images_prefetching then return end
    local missing = {}
    local fails = type(state._image_failures) == "table" and state._image_failures or {}
    for _i, vc in ipairs(state._view_images_missing or {}) do
        -- ⚠️ 已经失败过的不再自动重试：否则会变成
        --    「下载失败 → 重渲染 → 又进预取 → 再失败」的**死循环**（一直打服务器 + 一直刷屏）。
        --    用户点那一行（showCommentImage）才是重试入口。
        if not fails[vc.path] then
            missing[#missing + 1] = vc
        end
    end
    if #missing == 0 then return end
    state._images_prefetching = true
    local self_ref = self
    local client = self.client
    local pos = 0

    -- 图片回填的**合并节流**。
    --
    -- 🔴 为什么要合并：CommentView:refresh() 是「整树重建」，而图片是逐张下完的 ——
    --    每张都立刻重建一次 ⇒ ① 屏幕上一直闪（重建后要整块重绘）；
    --    ② 一页 N 张图会留下 N 棵内容树的 blitbuffer 等 GC（小内存设备上
    --    反复开关评论区就是「闪退」）。把 250ms 内的多次完成合并成一次重建，
    --    观感上仍是「分批浮现」，但只重绘一次、只产生一棵待回收的树。
    local render_scheduled = false
    local function schedule_render()
        if render_scheduled then return end
        render_scheduled = true
        UIManager:scheduleIn(0.25, function()
            render_scheduled = false
            local st = self_ref._para_view_state
            if not st or st.index ~= index then return end
            -- 🔴 视图已经不在屏幕上（用户翻了页/点了关闭）时**不要**重新弹出来：
            --    `in_place=true` 的语义是「刷新正显示着的这一份」；没人看就渲染的话，
            --    `C.viewer_is_shown` 为假 ⇒ 走新建分支 ⇒ 已关掉的旧页以「幽灵窗」还魂，
            --    压在翻页 loading 上面（本条曾与「点下一页」竞态实踩）。
            if not C.viewer_is_shown(self_ref._para_viewer) then return end
            self_ref:_renderParaReviewView(true)
        end)
    end

    local function next_one()
        if not self_ref._para_view_state or self_ref._para_view_state.index ~= index then
            return -- 视图已切走
        end
        pos = pos + 1
        local job = missing[pos]
        if not job then
            self_ref._para_view_state._images_prefetching = false
            return
        end
        -- 存在**且新鲜**才跳过：过期图进了 missing 清单（view_image_entries 把它
        -- 「当没有」），这里若只判 file_exists 会永远跳过 ⇒ 占位行卡在「正在加载」。
        if H.file_exists(job.path) and comment_image_fresh(self_ref, job.path) then
            next_one()
            return
        end
        Async.run(function()
            -- referer=false：fqnovelpic 系 CDN 实测对 Referer 做防盗链
            -- fetch_url：HEIC 已换成无签名 host + 公共模板（服务端转码成 WebP）
            local data = client:get_binary(job.im.fetch_url or job.im.url, { referer = false })
            if not data or #data == 0 then
                error("图片下载失败（响应为空）", 0)
            end
            H.write_file(job.path, data)
            return { path = job.path }
        end, function(ok, res)
            local st = self_ref._para_view_state
            if st and type(st._image_failures) == "table" then
                -- 成功要把失败标记清掉：否则这张图会一直显示「加载失败」
                st._image_failures[job.path] = nil
            end
            if ok and type(res) == "table" and res.path then
                -- 回填：把占位换成真图，原地刷新
                for _i, vc in ipairs((self_ref._para_view_state or {})._view_images_missing or {}) do
                    if vc.path == res.path then
                        vc.done = true
                        break
                    end
                end
                schedule_render()
            elseif st then
                -- 失败：记下来（视图会显示「加载失败，点这行重试」）并立刻重渲染
                if type(st._image_failures) ~= "table" then st._image_failures = {} end
                st._image_failures[job.path] = true
                if Log then Log.warn("段评图片下载失败:", tostring(job.path), tostring(res)) end
                schedule_render()
            end
            next_one()
        end, { poll_interval = 0.25, timeout = 45, tag = "comment_image" })
    end
    next_one()
end

-- 当前**阅读字号**（逻辑值，未 DPI 缩放）—— 段评 / 评论区的字号按它折算，
-- 这样「正文调大了，评论区跟着大」（用户反馈「评论区字还是太小」）。
-- 取法优先级：当前文档 `font_size`（crengine，用户真正在调的那个）→ 全局 `cre_font_size`
-- → 全局 `font_size` → nil（交给 comment_view 用默认基准兜底）。
-- ⚠️ mupdf 的 `font_size` 是 1.0 量级的倍数、crengine 是 12~64 的 pt 级数
--    （KOReader 自己就用 `<5` / `>5` 区分这两种语义）⇒ 区间外的值一律当读不到，
--    否则 mupdf 用户的评论区会被算成 1pt。
function M:_readerFontSize()
    local function sane(v)
        v = tonumber(v)
        if v and v >= 12 and v <= 64 then return v end
        return nil
    end
    local size
    if self.ui and self.ui.doc_settings and self.ui.doc_settings.readSetting then
        size = sane(self.ui.doc_settings:readSetting("font_size"))
    end
    if not size then
        local ok, rs = pcall(function() return G_reader_settings end)
        if ok and rs and rs.readSetting then
            size = sane(rs:readSetting("cre_font_size")) or sane(rs:readSetting("font_size"))
        end
    end
    return size
end

-- 渲染段评视图（优先 CommentView；不可用时退回纯文本 TextViewer）。
function M:_renderParaReviewView(in_place)
    if not CommentView then
        return self:_renderParaReviewText(in_place)
    end
    local state = self._para_view_state
    if not state then return end
    local comments = state.comments
    local Comments = require("fanqie.reading.comments")

    local cache = state.ident and self._para_pages and self._para_pages[state.ident] or nil
    local cache_expanded = (cache and cache.expanded) or {}
    local cache_replies = (cache and cache.replies) or {}

    local view_comments = {}
    local all_missing = {}
    for i, comment in ipairs(comments) do
        local cid = comment.comment_id and tostring(comment.comment_id) or nil
        local expanded = nil
        if cid and cache_expanded[cid] then
            local rs = cache_replies[cid]
            expanded = {
                roots = Comments.build_reply_tree((rs and rs.flat) or {}),
                has_more = (rs and rs.has_more) == true,
                total = tonumber(rs and rs.total) or 0,
            }
        end
        local user = tostring(comment.user_name or comment.username or _("匿名"))
        local likes = tonumber(comment.digg_count or comment.like_count) or 0
        local replies = tonumber(comment.reply_count) or 0
        -- v2.16.11 头行瘦身：只留「序号. 用户名+头衔」——日期/赞/回复数太挤
        --（用户报「第一行东西太多」），全部挪到**正文下面**的统计行 foot。
        local head = T(_("%1. %2%3"), tostring(i),
            user, C.comment_titles_text(comment))
        -- 统计行（comment_view 渲染成灰字小号，紧跟在正文/图片之后）：♥N  时间
        -- （v2.16.32 起点赞数前缀由「赞N」改为「♥N」、回复数移出这一行）
        -- v2.16.14：折叠标记**从这行里分出去**（用户：「时间、回复数、点赞数应该是灰色，
        -- 展开 m 条回复应该是白色，展开 n 条回复应该单独开一行」）—— 统计是信息（灰），
        -- 展开/收起是操作（正文色、单独一行、紧贴回复树）。
        local ts = C.fmt_comment_time(comment.create_time)
        -- v2.16.32：点赞改爱心（♥）；回复数从统计行去掉（折叠行「展开 N 条回复」
        -- 是操作、单独成行且用正文色 —— 同一个数字灰一遍白一遍只有噪音）。
        local foot = T(_("♥%1"), tostring(likes))
        if ts ~= "" then foot = foot .. "  " .. ts end
        -- 折叠标记（nil = 该条没有回复、也没展开 ⇒ 不显示这一行）
        local fold
        if expanded then
            fold = _("收起回复")
        elseif replies > 0 then
            fold = T(_("展开 %1 条回复"), tostring(replies))
        end

        local imgs, missing = view_image_entries(self, comment, i, true)
        for _k, m in ipairs(missing) do all_missing[#all_missing + 1] = m end

        local rc, more, reply_missing
        if expanded then
            rc, reply_missing = build_reply_blocks(self, expanded.roots)
            for _k, m in ipairs(reply_missing or {}) do all_missing[#all_missing + 1] = m end
            if expanded.has_more then
                more = math.max(1, (expanded.total or 0) - #(expanded.roots or {}))
            end
            -- v2.16.11 诊断（用户报「展开后二级回复空白」且设备日志零报错——
            -- 合并 flat=3 成功、无闸门 WARN、无 error ⇒ 嫌疑只剩渲染侧）：
            --   · roots=0     → build_reply_tree 把条全丢了（reply_id 缺失/畸形）
            --   · blocks=0 但 roots>0 → build_reply_blocks 丢了
            -- 两种都不许静默空白：落 WARN 留证据 + 渲染一行灰字说明。
            if rc == nil or #rc == 0 then
                local flat_n = #(cache_replies[cid] and cache_replies[cid].flat or {})
                if Log then
                    Log.warn("[段评] 展开后零回复块: cid=" .. tostring(cid)
                        .. " roots=" .. #(expanded.roots or {})
                        .. " flat=" .. tostring(flat_n)
                        .. " total=" .. tostring(expanded.total))
                end
                rc = { { head = _("（回复内容解析为空 —— 请把 fanqie.log 里「展开后零回复块」这行发给开发者）"),
                        text = "", images = {} } }
            end
        end

        -- 可点载荷（**不透明**，语义在这里；comment_view 只负责原样回传）：
        --   tap      = 点「头行 + 正文」→ 该条展开/收起（只有回复数 >0 或已展开才可点）
        --   more_tap = 点「… 还有 N 条回复」→ 该条继续加载
        -- 0 回复且未展开的评论**不给 tap**：否则点一下会白发一次 commentapi 请求，
        -- 而那种评论本来就不显示折叠标记（与上面 head 的判据保持一致）。
        local tap, more_tap
        if (replies > 0) or expanded then
            tap = { no = i, collapse = (expanded ~= nil) }
        end
        if more then
            more_tap = { no = i, more = true }
        end

        view_comments[#view_comments + 1] = {
            no = i,
            head = head,
            foot = foot,
            fold = fold,
            text = tostring(comment.text or ""),
            images = imgs,
            replies = rc,
            more_replies = more,
            tap = tap,
            more_tap = more_tap,
        }
    end
    state._view_images_missing = all_missing

    -- 单条点击的落点：comment_view 只回传 payload，这里负责翻成一次请求/渲染。
    -- 复用 showParaReviewReplies（它自己做了「收起=零请求」「已缓存=零请求」
    -- 「more 且没更多=提示」三种快速分支，以及失效状态守卫）。
    local index_ref = state.index
    local on_block_tap = function(t)
        if type(t) ~= "table" then return end
        if t.more then
            self:showParaReviewReplies(index_ref, t.no, { more = true })
        else
            self:showParaReviewReplies(index_ref, t.no, { collapse = t.collapse })
        end
    end
    -- 点段评图 → 全屏预览（与回退路径的「图N·k」按钮同一个落点）。
    -- 未缓存的图由 showCommentImage 自己下载，所以不必等预取完成。
    local on_image_tap = function(t)
        if type(t) ~= "table" then return end
        self:showCommentImage(index_ref, t.no, t.img)
    end

    -- 底部按钮（固定数量，不随评论条数增长）
    -- v2.16.8 起**不再有「展开全部回复」批量按钮**：单条展开/收起靠点头行，
    -- 更多回复靠「… 还有 N 条回复」行，批量开关的收益小于它占的一行空间。

    local page = state.page or 1
    local has_more = state.info.has_more == true
    local total = state.total or 0
    local total_pages = nil
    if total > C.PARA_REVIEW_PAGE_SIZE then
        total_pages = math.ceil(total / C.PARA_REVIEW_PAGE_SIZE)
    end

    local buttons_table = {}
    local page_row = {}
    -- 🔴 翻页/关闭按钮**绝不**在回调里直接 `UIManager:close` 再开新窗（v2.16.0 实测真机
    --    「点下一页秒闪退」的根因）。两个独立的坑：
    --    ① 回调此刻还在**按钮自己的手势分发**里，而且 flash_ui 开着时 Button 的回调
    --       前后还要穿插高亮/取消高亮的即时重绘（见 ui/widget/button.lua
    --       onTatSelectButton 的长注释：官方明确写了「回调可能关掉自己」并为此绕路）——
    --       在这个当口把整棵控件树（包括那个正在执行回调的 Button 自己）free 掉，
    --       是真机 segfault 的经典姿势；
    --    ② 「先关窗、再异步取数」会和图片预取的 schedule_render 竞态：定时器先到的话，
    --       `_renderParaReviewView(true)` 看不到已显示的视图，会把**旧页**当新窗重新弹出来。
    --    修法：nextTick 把动作挪出手势分发；旧窗保留到新数据就绪，由
    --    `_renderParaReviewView(false)` 的 else 分支统一「关旧开新」——
    --    墨水屏上还少一次闪空白。
    if page > 1 then
        page_row[#page_row + 1] = {
            text = _("上一页"),
            callback = function()
                UIManager:nextTick(function()
                    self:showParaReviewDetail(state.index, { page = page - 1 })
                end)
            end,
        }
    end
    if has_more or (total_pages and page < total_pages) then
        page_row[#page_row + 1] = {
            text = _("下一页"),
            callback = function()
                UIManager:nextTick(function()
                    self:showParaReviewDetail(state.index, { page = page + 1 })
                end)
            end,
        }
    end
    page_row[#page_row + 1] = {
        text = _("关闭"),
        callback = function()
            UIManager:nextTick(function()
                local v = self._para_viewer
                -- 🔴 走 `CommentView:onClose` 而不是裸 `UIManager:close`：
                --    它是「用户主动关闭」的唯一语义入口，会在关窗后按需补一次**全刷**
                --    （视图里有内嵌图片时不刷会留残影），并且会连带触发 `on_close`
                --    清掉 `_para_viewer` 句柄。裸 close 两件事都漏。
                if v and v.onClose then
                    pcall(v.onClose, v)
                elseif v then
                    pcall(function() UIManager:close(v) end)
                end
                self._para_viewer = nil
            end)
        end,
    }
    buttons_table[#buttons_table + 1] = page_row

    -- v2.16.8 起标题不带「第几条/共几条」：翻页指示（第X/Y页）保留在后面。
    -- v2.16.32：标题改「N 条回复」（对齐 App 的评论区顶栏）；total 拿不到时退回
    -- 「段评」。翻页指示（第X/Y页）保留在后面（v2.16.8 口径不变）。
    local viewer_title = total > 0
        and T(_("%1 条回复"), tostring(total))
        or _("段评")
    if total_pages then
        viewer_title = viewer_title .. T(_(" 第%1/%2页"), tostring(page), tostring(total_pages))
    end

    local need_prefetch = #all_missing > 0
    if in_place and C.viewer_is_shown(self._para_viewer) and self._para_viewer.refresh then
        -- 原地重建（CommentView:refresh 保持滚动比例；图片逐张回填时页面不跳）
        -- ⚠️ on_block_tap / on_image_tap 都必须一起换：闭包捕获的是**本次渲染**的
        --    index_ref，复用旧闭包会在换段后打到旧段落上
        --    （refresh 只重建内容，不重建实例）。
        local viewer = self._para_viewer
        viewer.title = viewer_title
        viewer.comments = view_comments
        viewer.buttons_table = buttons_table
        viewer.on_block_tap = on_block_tap
        viewer.on_image_tap = on_image_tap
        -- 阅读字号可能在读书过程中被调过 ⇒ 一起刷新（清掉缓存，refresh 会重算并重建内容树）
        viewer.reader_font_size = self:_readerFontSize()
        viewer._font_head = nil
        viewer:refresh()
    else
        if self._para_viewer and self._para_viewer.onClose then
            pcall(function() UIManager:close(self._para_viewer) end)
        end
        self._para_viewer = CommentView:new{
            title = viewer_title,
            comments = view_comments,
            buttons_table = buttons_table,
            on_block_tap = on_block_tap,
            on_image_tap = on_image_tap,
            -- 字号跟正文走（读不到就给 nil，comment_view 用默认基准）
            reader_font_size = self:_readerFontSize(),
            on_close = function()
                -- 关窗后清掉句柄，避免下次对已关闭的 widget 调 refresh
                self._para_viewer = nil
            end,
        }
        UIManager:show(self._para_viewer)
    end
    if need_prefetch then
        UIManager:scheduleIn(0.2, function()
            self:_prefetchParaImages(state.index)
        end)
    end
end

-- [兜底渲染器] TextViewer 纯文本版：CommentView（fanqie/comment_view.lua）加载
-- 失败时使用。文案口径与新视图一致，但没有内嵌图片（只有【图片】提示行）。
function M:_renderParaReviewText(in_place)
    local state = self._para_view_state
    if not state then return end
    local comments = state.comments

    local cache = state.ident and self._para_pages and self._para_pages[state.ident] or nil
    local cache_expanded = (cache and cache.expanded) or {}
    local cache_replies = (cache and cache.replies) or {}
    local Comments = require("fanqie.reading.comments")

    local text_parts = {}
    local reply_buttons = {}
    for i, comment in ipairs(comments) do
        local cid = comment.comment_id and tostring(comment.comment_id) or nil
        local expanded = nil
        if cid and cache_expanded[cid] then
            local rs = cache_replies[cid]
            expanded = {
                roots = Comments.build_reply_tree((rs and rs.flat) or {}),
                has_more = (rs and rs.has_more) == true,
                total = tonumber(rs and rs.total) or 0,
            }
        end
        text_parts[#text_parts + 1] = table.concat(C.append_comment_lines(i, comment, expanded), "\n")

        if cid then
            local n = tonumber(comment.reply_count) or 0
            local is_open = cache_expanded[cid] == true
            if n > 0 or is_open then
                local index_ref = state.index
                local no = i
                reply_buttons[#reply_buttons + 1] = {
                    text = is_open and T(_("%1 收起"), tostring(i))
                        or T(_("%1 展开%2条回复"), tostring(i), tostring(n)),
                    callback = function()
                        self:showParaReviewReplies(index_ref, no, { collapse = is_open })
                    end,
                }
                local rs = cache_replies[cid]
                if is_open and rs and rs.has_more then
                    reply_buttons[#reply_buttons + 1] = {
                        text = T(_("%1 ⋯"), tostring(i)),
                        callback = function()
                            self:showParaReviewReplies(index_ref, no, { more = true })
                        end,
                    }
                end
            end
        end

        -- 段评图片：每张「可显示」的图一个按钮。
        -- 不可显示的（HEIC）**不给按钮**，理由已写进正文的图片提示行，
        -- 免得按钮点下去只能弹一句"打不开"。
        for _k, im in ipairs(C.comment_images(comment)) do
            if im.displayable then
                local index_ref2 = state.index
                local no2, kn2 = i, _k
                reply_buttons[#reply_buttons + 1] = {
                    text = T(_("图%1·%2"), tostring(i), tostring(_k)),
                    callback = function()
                        self:showCommentImage(index_ref2, no2, kn2)
                    end,
                }
            end
        end
    end

    local buttons_table = {}
    for i = 1, #reply_buttons, C.REPLY_BUTTONS_PER_ROW do
        local row = {}
        for j = i, math.min(i + C.REPLY_BUTTONS_PER_ROW - 1, #reply_buttons) do
            row[#row + 1] = reply_buttons[j]
        end
        buttons_table[#buttons_table + 1] = row
    end

    -- 分页状态（__page 由 showParaReviewDetail 标记）
    local page = state.page or 1
    local has_more = state.info.has_more == true
    local total = state.total or 0
    local total_pages = nil
    if total > C.PARA_REVIEW_PAGE_SIZE then
        total_pages = math.ceil(total / C.PARA_REVIEW_PAGE_SIZE)
    end

    local page_row = {}
    -- 🔴 与 CommentView 版同理（见那边长注释）：不要在按钮手势分发里直接关窗，
    --    一律 nextTick 挪出去，旧窗留给 `_renderParaReviewView` 统一关。
    if page > 1 then
        page_row[#page_row + 1] = {
            text = _("上一页"),
            callback = function()
                UIManager:nextTick(function()
                    self:showParaReviewDetail(state.index, { page = page - 1 })
                end)
            end,
        }
    end
    if has_more or (total_pages and page < total_pages) then
        page_row[#page_row + 1] = {
            text = _("下一页"),
            callback = function()
                UIManager:nextTick(function()
                    self:showParaReviewDetail(state.index, { page = page + 1 })
                end)
            end,
        }
    end
    if #page_row > 0 then
        buttons_table[#buttons_table + 1] = page_row
    end

    buttons_table[#buttons_table + 1] = {
        {
            text = _("关闭"),
            callback = function()
                UIManager:nextTick(function()
                    local v = self._para_viewer
                    -- 与 CommentView 版同理：走官方 `TextViewer:onClose`（内部会调
                    -- `close_callback` 清句柄），而不是裸 `UIManager:close`。
                    -- 本回退路径没有内嵌图片，所以不需要补全刷。
                    if v and v.onClose then
                        pcall(v.onClose, v)
                    elseif v then
                        pcall(function() UIManager:close(v) end)
                    end
                    self._para_viewer = nil
                end)
            end,
        },
    }

    -- v2.16.8 起标题不带「第几条/共几条」（与 CommentView 主路径同口径）
    -- v2.16.32：标题改「N 条回复」，同主路径。
    local viewer_title = (state.total or 0) > 0
        and T(_("%1 条回复"), tostring(state.total))
        or _("段评")
    if total_pages then
        viewer_title = viewer_title .. T(_(" 第%1/%2页"), tostring(page), tostring(total_pages))
    end

    local text = table.concat(text_parts, "\n\n")
    if in_place and C.viewer_is_shown(self._para_viewer) then
        -- 原地重排：TextViewer:reinit() 会按可见高度比例还原滚动位置
        local viewer = self._para_viewer
        viewer.text = text
        viewer.title = viewer_title
        viewer.buttons_table = buttons_table
        viewer:reinit()
    else
        self._para_viewer = TextViewer:new{
            title = viewer_title,
            text = text,
            text_type = "book_info",
            justified = false,
            buttons_table = buttons_table,
            close_callback = function()
                -- 关窗后清掉句柄，避免下次对已关闭的 widget 调 reinit
                self._para_viewer = nil
            end,
        }
        UIManager:show(self._para_viewer)
    end
end

-- 展开 / 收起 / 继续加载某条段评的回复（reply/list，异步）。
-- comment_no 是本页评论序号（1-based）；opts = { collapse=true | more=true }。
-- ⚠️ 回复请求与段评列表同属 commentapi：签名不合规时服务端回 **200 空响应**，
--    client 层把它转成 (nil, err)，这里必须显示成错误，
--    不能退化成「这条没有回复」——两者症状一样但含义完全相反。
function M:showParaReviewReplies(index, comment_no, opts)
    opts = opts or {}
    local state = self._para_view_state
    if not state or state.index ~= index then
        self:showInfo(_("段评数据已失效，请重新打开"))
        return
    end
    local comment = state.comments[comment_no]
    local cid = comment and comment.comment_id and tostring(comment.comment_id) or nil
    if not cid then
        self:showInfo(_("段评数据无效"))
        return
    end
    local cache = state.ident and self._para_pages and self._para_pages[state.ident] or nil
    if not cache then
        self:showInfo(_("段评数据已失效，请重新打开"))
        return
    end
    cache.expanded = cache.expanded or {}
    cache.replies = cache.replies or {}
    local rs = cache.replies[cid]
    if not rs then
        rs = { flat = {}, pages = 0, cursor = "", has_more = true, total = 0 }
        cache.replies[cid] = rs
    end

    -- 收起
    if opts.collapse then
        cache.expanded[cid] = nil
        self:_renderParaReviewView(true)
        return
    end
    -- 已有数据且不是「继续加载」→ 纯展开，零请求
    if not opts.more and (rs.pages or 0) > 0 then
        cache.expanded[cid] = true
        self:_renderParaReviewView(true)
        return
    end
    if opts.more and not rs.has_more then
        self:showInfo(_("没有更多回复了"))
        return
    end

    -- 实际拉取复用 _fetchParaReplies（游标/上限/busy/子进程/合并都在那边），
    -- 这里只负责快速分支与「成功后展开 + 重渲染」。
    local self_ref = self
    self:_fetchParaReplies(index, comment_no, function(ok)
        if ok then
            cache.expanded[cid] = true
            self_ref:_renderParaReviewView(true)
        end
    end)
end

-- 段评图片的本地缓存目录（与章节缓存同根，便于「缓存管理」一起统计/清理）。
function M:_comment_image_dir()
    local base
    if self.settings and self.settings.get_download_dir then
        base = self.settings:get_download_dir()
    end
    if not base or base == "" then
        base = H.get_data_dir()
    end
    return H.join_path(base, "comment_images")
end

-- 查看段评里的一张图片。
-- 缓存命中直接开；未命中在子进程下载（UI 线程零阻塞）后开。
--
-- ⚠️ 图片 URL 是**带签名的**（x-expires 约 1 个月）。实测三件事：
--    · 改扩展名（.heic→.jpeg）、去掉 query、换无签名 host —— 全部 403；
--    · 换 Accept 头（image/webp / image/jpeg / */*）—— 服务端不做内容协商，
--      返回的内容类型恒定；
--    → 只能**原样**下载再本地缓存，任何"看起来更友好"的 URL 改写都会失败。
function M:showCommentImage(index, comment_no, img_no)
    local state = self._para_view_state
    if not state or state.index ~= index then
        self:showInfo(_("段评数据已失效，请重新打开"))
        return
    end
    local comment = state.comments[comment_no]
    local list = C.comment_images(comment)
    local im = list[img_no]
    if not im or im.url == "" then
        self:showInfo(_("图片不存在"))
        return
    end
    if not im.displayable then
        self:showInfo(T(_("该图片为 %1 格式，本设备无法显示"),
            string.upper(tostring(im.format or "HEIC"))))
        return
    end

    -- 与内嵌渲染共用同一个路径函数（后缀白名单见 para_image_path 的注释）——
    -- 两边各写一份的话，改了一处就会出现「内嵌能显示、点开却说文件不存在」。
    local path = para_image_path(self, comment, comment_no, img_no, im)

    -- v2.16.9.1：with_title_bar=false 只去了标题栏；不传 fullscreen=true 时
    -- ImageViewer 仍是**居中圆角 + 四周留边**的浮动对话框（radius=8 + padding，
    -- 见 imageviewer.lua fullscreen 语义）——那就是用户眼里的「中间那层弹窗」。
    -- 补 fullscreen=true：覆盖整屏、无圆角，与 KOReader 自身「长按图片查看」
    -- （readerhighlight）完全同款；「原尺寸 / 旋转 / 关闭」按钮点屏呼出不变。
    local self_ref = self
    local function open_file(p)
        if not ImageViewer then
            self_ref:showInfo(_("图片查看器不可用"))
            return
        end
        UIManager:show(ImageViewer:new{
            file = p,
            with_title_bar = false,
            fullscreen = true,
        })
    end

    -- 缓存命中也要新鲜（过期重下，见 comment_image_fresh 的注释）
    if H.file_exists(path) and comment_image_fresh(self, path) then
        open_file(path)
        return
    end

    self:showBusy(_("正在下载图片..."))
    if not (Async and Async.run) then
        self:closeBusy()
        self:showInfo(_("异步模块不可用，无法下载图片"))
        return
    end
    local client = self.client
    Async.run(function()
        -- referer=false：fqnovelpic 系 CDN 实测对 Referer 做防盗链
        -- fetch_url：HEIC 已换成无签名 host + 公共模板（服务端转码成 WebP）
        local data = client:get_binary(im.fetch_url or im.url, { referer = false })
        if not data or #data == 0 then
            error("图片下载失败（响应为空）", 0)
        end
        H.write_file(path, data)
        return { path = path }
    end, function(ok, res, err)
        self_ref:closeBusy()
        if not ok or type(res) ~= "table" or not res.path then
            if Log then Log.error("[段评] 图片下载失败:", tostring(err or res)) end
            self_ref:showInfo(T(_("图片下载失败: %1"), tostring(err or res)))
            return
        end
        -- 手动重试成功：清掉失败标记并重渲染，那张「加载失败」占位行会就地变成真图
        local st = self_ref._para_view_state
        if st and type(st._image_failures) == "table" and st._image_failures[path] then
            st._image_failures[path] = nil
            self_ref:_renderParaReviewView(true)
        end
        open_file(res.path)
    end, { poll_interval = 0.125, timeout = 45, tag = "comment_image" })
end

-- 段评异步获取已迁移至 showParaReviewDetail / _displayParaReviewDetail


-- ============================================================================
-- 段评链接拦截
-- ============================================================================

return M
