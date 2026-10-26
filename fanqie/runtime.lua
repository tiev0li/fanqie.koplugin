-- fanqie/runtime.lua —— 主插件各动作模块共享的运行时依赖与小型工具。
--
-- 这里只承载跨职责复用的基础设施；业务流程仍在各动作模块中。
-- state 是唯一共享状态源，禁止各模块另建可变副本。

local Content = require("fanqie.content")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template

local M = {}

M.state = require("fanqie.state")

-- 由 main.lua 注入；动作文件的位置不能用来推断插件根目录。
M.plugin_path = "."

local ok_socket, socket = pcall(require, "socket")

--- 墙钟计时（秒）。父进程等待子进程时 os.clock() 几乎不累加。
function M.now_seconds()
    if ok_socket and socket and socket.gettime then
        return socket.gettime()
    end
    return os.clock()
end

--- 日志中的异常文本：压平控制字符并限制长度。
function M.log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

function M.is_auth_error(err)
    return type(err) == "table" and err.auth_expired == true
end

--- 面向用户的错误摘要，保留原有的登录过期文案与截断口径。
function M.display_error(err)
    if M.is_auth_error(err) then
        return _("登录已过期，请更新 Cookie\n\n请编辑 config.lua 文件，填入最新的 Cookie 值后重新启动插件。")
    end
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

--- 当前章节索引。未进入章节时沿用 0 哨兵，不改成 nil。
function M.getCurrentChapterIndex()
    return M.state.current_chapter_index or 0
end

--- 书籍章节缓存的懒加载入口，保持 cached_chapters 的引用共享。
function M.getCachedChapters(plugin, book)
    if not book then
        return {}
    end
    if not book.cached_chapters then
        book.cached_chapters = Content.load_cache_index(plugin.settings, book.book_id) or {}
    end
    return book.cached_chapters
end

--- 图集/漫画下载心跳：按约五分之一进度台阶更新忙碌提示。
function M.make_page_heartbeat(plugin, chapter, is_comic)
    if not is_comic or not plugin then return nil end
    local title = (chapter and chapter.title) or ""
    local last_shown = 0
    return function(text)
        local done_s, total_s, failed_s = tostring(text):match("^(%d+)/(%d+)/?(%d*)$")
        local done, total = tonumber(done_s), tonumber(total_s)
        if not (done and total and total > 0) then return end
        local failed = tonumber(failed_s) or 0
        local step = math.max(1, math.floor(total / 5))
        if done < total and done - last_shown < step then return end
        last_shown = done
        local msg = T(_("正在下载图集: %1\n（第 %2/%3 页）"), title, done, total)
        if failed > 0 then
            msg = msg .. T(_("（失败 %1 页）"), failed)
        end
        plugin:showBusy(msg)
    end
end

return M
