-- 进度与统计纯函数：百分比边界、未知降级、时长估算与聚合。
local root = (arg and arg[1]) or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local PS = require("fanqie.progress_stats")
local failures = 0
local function check(v, m) if not v then failures = failures + 1; io.stderr:write("FAIL: ", m, "\n") end end

-- book_progress：正常、边界、未知
check(PS.book_progress(1, 0, 100) == 0, "start is 0%")
check(PS.book_progress(50, 0.5, 100) == 49, "mid book 49%")
check(PS.book_progress(100, 1, 100) == 100, "finished is 100%")
check(PS.book_progress(100, 1.5, 100) == 100, "progress clamped, never >100%")
check(PS.book_progress(150, 0, 100) == 100, "index beyond total clamped")
check(PS.book_progress(nil, 0, 100) == nil, "unknown chapter -> nil")
check(PS.book_progress(5, 0, 0) == nil, "zero total -> nil")
check(PS.book_progress(5, 0, nil) == nil, "nil total -> nil")
-- chapter 百分比与剩余页
check(PS.chapter_percent(5, 10) == 50, "chapter 50%")
check(PS.chapter_percent(10, 10) == 100, "chapter 100%")
check(PS.chapter_percent(nil, 10) == nil, "unknown page -> nil")
check(PS.chapter_remaining(3, 10) == 7, "remaining pages")
check(PS.chapter_remaining(10, 10) == 0, "last page remaining 0")
check(PS.chapter_remaining(11, 10) == 0, "beyond last clamped to 0")
check(PS.chapter_remaining(1, nil) == nil, "unknown total -> nil")
-- estimate：样本不足返回 nil
check(PS.estimate_seconds({}, 10) == nil, "no samples -> nil")
check(PS.estimate_seconds({ 5, 6 }, 10) == nil, "two samples -> nil")
check(PS.estimate_seconds({ 5, 6, 7 }, 10) == 60, "median 6s * 10 pages")
check(PS.estimate_seconds({ 5, 6, 7 }, 0) == nil, "zero remaining -> nil")
check(PS.estimate_seconds({ -1, -2, -3 }, 10) == nil, "negative samples ignored -> nil")
-- aggregate
local store = {}
PS.aggregate_duration(store, "1", 60, 100)
PS.aggregate_duration(store, "1", 30, 200)
PS.aggregate_duration(store, "2", 10, 50)
PS.aggregate_duration(store, "1", -5, 300)
check(store["1"].seconds == 90, "duration accumulates, negatives ignored")
check(store["1"].last_ts == 200, "last_ts is max")
check(store["2"].seconds == 10, "second book separate")
if failures > 0 then os.exit(1) end
print("Progress stats: OK")
