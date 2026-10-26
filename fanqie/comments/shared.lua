local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template
local UIManager = require("ui/uimanager")

local C = {}
-- fanqie/comments/shared.lua —— 段评两条链路（数据/渲染）共享的常量与纯函数。
--
-- 从 comment_actions.lua 原样迁出：口径注释与实现一字未改。
-- 段评列表分页大小：comment_actions 用它控制请求条数，comment_view_actions
-- 用它算「第 X/Y 页」。两处口径必须同源，所以放在共享模块里，别各写一份。
C.PARA_REVIEW_PAGE_SIZE = 10
-- ===========================================================================
-- 段评树状渲染（顶层段评 + 其回复串）
-- ===========================================================================
-- 层次结构：段评（comment/list）→ 回复（reply/list，reply_to_reply_id 指向父回复）。
-- TextViewer 只能画纯文本、且**不支持行内可点区域**，所以这里的「树」分两层落地：
--   * 层级用**缩进**表达（每层 1 个全角空格，深度封顶，避免深链挤成竖排）；
--   * 展开/收起靠底部按钮，状态存在 self._para_pages[ident]（跨弹窗生命周期）；
--     状态变化后调用 TextViewer:reinit() **原地重排**（reinit 内部按可见高度比例
--     还原滚动位置），而不是关窗重开 —— 否则展开列表深处的一条回复会把视图弹回顶部。
C.REPLY_INDENT      = "\u{3000}"  -- 全角空格
C.REPLY_INDENT_MAX  = 4           -- 最大缩进层级
C.PARA_REPLY_PAGE_SIZE = 20       -- 每次拉取的回复条数（服务端上限 50）
C.PARA_REPLY_MAX_PAGES = 5        -- 单次展开最多连拉几页（防「回复上千条」时失控）
C.REPLY_BUTTONS_PER_ROW = 4       -- 每行放几个回复开关按钮

-- UIManager:isWidgetShown 是较新版本才有的 API；老版本退化为「句柄在即视为已显示」
-- （close_callback 已负责清句柄，所以这个兜底不会误用已关闭的 widget）
function C.viewer_is_shown(widget)
    if not widget then return false end
    if UIManager and type(UIManager.isWidgetShown) == "function" then
        local ok, shown = pcall(UIManager.isWidgetShown, UIManager, widget)
        return ok and shown or false
    end
    return true
end

function C.fmt_comment_time(raw)
    if type(raw) == "number" then
        return os.date("%Y-%m-%d %H:%M", raw)
    end
    if raw then
        return tostring(raw)
    end
    return ""
end

-- 头衔展示串：「［作家］［次元破壁神］［故事合伙人］」；没有头衔时返回 ""。
-- 数据由 Comments.titles_of 归一（`fanqie/reading/comments.lua`），这里只管
-- 组装与 i18n：`is_author` 单独补一个「作者」标记（接口的 is_author 与
-- user_title_info 里的「作家」是两回事，实测有 is_author=true 但头衔为空的）。
-- ⚠️ 放在「评论头行」之前，4 处头行（顶层/回复 × 主路径/回退路径）共用它，
--    别只改一处 —— 改动会被 _mutate_paretap.py 的变异抓住。
function C.comment_titles_text(comment)
    if type(comment) ~= "table" then return "" end
    local parts = {}
    if comment.is_author == true then parts[#parts + 1] = _("作者") end
    local titles = comment.titles
    if type(titles) == "table" then
        for _i, t in ipairs(titles) do
            if type(t) == "string" then
                -- 🔴 必须**去空白后再判空**：只写 `t ~= ""` 时，纯空白头衔
                --    （" " / "  "）会渲染成「［  ］」这种空括号。
                --    Comments.titles_of 那边本来就会 trim，这里再兜一次是为了
                --    「渲染层不依赖上游一定干净」（回归 D10/D11 压的就是这一条）。
                local name = t:match("^%s*(.-)%s*$")
                if name ~= "" then parts[#parts + 1] = name end
            end
        end
    end
    if #parts == 0 then return "" end
    for i = 1, #parts do parts[i] = "［" .. parts[i] .. "］" end
    return " " .. table.concat(parts)
end

-- 递归把回复树摊成文本行（缩进 + ↳ 前缀 + 「回复某人」）
-- ⚠️ 循环变量**不能**叫 `_`：本函数体内要调用 gettext 的全局 `_()`，
--    而 `for _, node in ...` 的 `_` 是局部变量，会把 `_()` 遮蔽成数字索引
--    （实测报 "attempt to call local '_' (a number value)"）。
function C.append_reply_lines(nodes, out)
    for _i, node in ipairs(nodes or {}) do
        local depth = math.min(tonumber(node.depth) or 0, C.REPLY_INDENT_MAX)
        local indent = string.rep(C.REPLY_INDENT, depth + 1)
        local to = ""
        if node.reply_to_user_name and node.reply_to_user_name ~= node.user_name then
            to = T(_(" 回复 %1"), tostring(node.reply_to_user_name))
        end
        local head = T(_("%1↳ %2%3%4 (♥%5)"), indent,
            tostring(node.user_name or _("匿名")), C.comment_titles_text(node), to,
            tonumber(node.digg_count) or 0)
        local ts = C.fmt_comment_time(node.create_time)
        if ts ~= "" then
            head = head .. "  " .. ts
        end
        out[#out + 1] = head
        local body = tostring(node.text or "")
        if body ~= "" then
            out[#out + 1] = indent .. "  " .. body
        end
        if node.children and #node.children > 0 then
            C.append_reply_lines(node.children, out)
        end
    end
end

-- 段评图片归一（薄封装，便于渲染与按钮两处共用同一份判定）。
function C.comment_images(comment)
    local ok, Comments = pcall(require, "fanqie.reading.comments")
    if not ok or type(Comments) ~= "table" or type(Comments.normalize_images) ~= "function" then
        return {}
    end
    local ok2, list = pcall(Comments.normalize_images, comment and comment.images)
    return (ok2 and type(list) == "table") and list or {}
end

-- 图片提示行：TextViewer 画不了图，只能把「有几张、哪几张能看」写进文本。
-- 不可显示的必须显式说明 —— 否则用户点开是空白，会以为插件坏了。
-- （HEIC 现在会先试着转码成 WebP，转不了才落到这里）
function C.comment_image_note(list)
    local n_ok, n_bad, bad_fmt = 0, 0, {}
    for _i, im in ipairs(list) do
        if im.displayable then
            n_ok = n_ok + 1
        else
            n_bad = n_bad + 1
            bad_fmt[string.upper(tostring(im.format or "HEIC"))] = true
        end
    end
    if n_ok == 0 and n_bad == 0 then return nil end
    local parts = {}
    if n_ok > 0 then
        parts[#parts + 1] = T(_("%1 张可看"), tostring(n_ok))
    end
    if n_bad > 0 then
        local names = {}
        for f in pairs(bad_fmt) do names[#names + 1] = f end
        table.sort(names)
        parts[#parts + 1] = T(_("%1 张为 %2，本设备无法显示"),
            tostring(n_bad), table.concat(names, "/"))
    end
    return T(_("【图片】%1"), table.concat(parts, "，"))
end

-- 一条顶层段评 → 文本行（含已展开的回复树）。
-- expanded 为 nil 表示收起；否则为 { roots = 树, has_more = bool, total = n }。
function C.append_comment_lines(number, comment, expanded)
    local user = tostring(comment.user_name or comment.username or _("匿名"))
    local likes = tonumber(comment.digg_count or comment.like_count) or 0
    local replies = tonumber(comment.reply_count) or 0
    -- v2.16.11 与 CommentView 主路径同口径：头行只留「序号. 用户名」，
    -- 日期/赞/回复数 + 折叠标记挪到正文下面的统计行。
    local head = T(_("%1. %2%3"), number,
        user, C.comment_titles_text(comment))
    local out = { head }
    local body = tostring(comment.text or "")
    if body ~= "" then
        out[#out + 1] = body
    end
    local ts = C.fmt_comment_time(comment.create_time)
    -- v2.16.32：点赞改爱心（♥），回复数从统计行去掉（「展开 N 条回复」操作行
    -- 已经在下面单独成行，数字写两遍只有噪音 —— 用户原话「去除回复n条」）。
    local foot = T(_("♥%1"), tostring(likes))
    if ts ~= "" then foot = foot .. "  " .. ts end
    out[#out + 1] = foot
    -- v2.16.14 与主路径同口径：折叠标记单独一行（纯文本回退路径没有颜色可言，
    -- 但仍然不许跟统计挤在同一行）。
    if expanded then
        out[#out + 1] = _("收起回复")
    elseif replies > 0 then
        out[#out + 1] = T(_("展开 %1 条回复"), tostring(replies))
    end
    local note = C.comment_image_note(C.comment_images(comment))
    if note then
        out[#out + 1] = note
    end
    if expanded then
        if expanded.roots and #expanded.roots > 0 then
            C.append_reply_lines(expanded.roots, out)
        else
            out[#out + 1] = _("（回复内容解析为空）")
        end
        if expanded.has_more then
            out[#out + 1] = C.REPLY_INDENT .. _("… 还有更多回复，点下方「⋯」继续加载")
        end
    end
    return out
end

return C
