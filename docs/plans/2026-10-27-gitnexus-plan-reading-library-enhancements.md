# GitNexus Engineering Plan

> Task: 分阶段交付追更、缓存/离线、历史/冲突、目录导航、统计和安全备份六项功能。
> Evidence verified at commit 52b12ca7518ff42449a266d4cc57a1bdc78d003b; GitNexus refreshed this session with `analyze --index-only --pdg` (runner 1.6.12, distribution identity current).
> Evidence provenance schema 2; global dirty digest 28bbd7e6e48febfaa8ac5f4dc78b521d2cdcb8c4cb8b68fda32fd3e2d22b46df; cited-path manifest 18 sorted entries; exact generated plan path excluded.

## 1. Objective

交付六个完整、可离线退化、可独立验收的增量：①追更中心及更新提醒；②按书缓存与离线管理；③阅读历史及云端/本地冲突选择；④目录搜索、章号跳转及返回原位；⑤本章/全书进度和按书统计；⑥不含凭证的本地备份与恢复。 [verified] 复用现有书架、目录、下载和统计基础设施，不增加第三方服务。

## 2. Current Behaviour

- [verified] `Bookshelf:showBookshelf` 先画缓存、后台刷新，只在成功且非空时覆盖缓存（`fanqie/bookshelf.lua:261-430`）。书架已能显示总章数与已读章数，但没有跨书目录检查或更新中心。
- [verified] `openBook` 有缓存时立即阅读，再由 `_refreshCatalogInBackground` 拉目录/进度；仅当前缀完全一致时向活动目录追加新章（`fanqie/opening/open_book_actions.lua:72-193,196-330`）。
- [verified] 云端更靠后目前仅 `markCloudAhead` 并提示下次进入跳过去；本地则由待传队列和当前会话取最大章号（`fanqie/state.lua:380-442`）。尚未有页级历史或冲突选择。
- [verified] 目录已经支持合法范围内的章号输入及缓存标记（`fanqie/chapters/chapter_actions.lua:38-292`），但缺标题搜索和返回跳转前位置。
- [verified] 下载器是异步、可取消、按节流的单任务（`fanqie/download.lua:82-285`）；缓存统计只有全书总量，单书删除为整目录删除（`fanqie/settings.lua:576-667`）。
- [verified] 统计已将章节映射成一本书的固定身份，并以每章 100 个虚拟页槽保持跨章页号不覆盖（`fanqie/stats.lua:177-229,245-351`）。

## 3. Relevant Architecture

`main.lua` 负责生命周期与动作模块挂载；`bookshelf/shelf_view` 是数据与显示分离；`content` 统一持久化目录、章节索引；`opening/chapters/reader` 分别负责开书决策、目录/导航、阅读会话；`settings/state` 分别持有持久设置与进程状态。新增领域模块保持同样边界：

- `fanqie/library.lua`：按 `book_id` 的本地资料库，含阅读位置、追更快照、每书缓存元数据，独立于云端书架，避免把本地状态混入接口响应。
- `fanqie/update_center.lua` / `fanqie/cache_manager.lua` / `fanqie/backup.lua`：无 UI 或轻 UI 的领域操作；`fanqie/library_view.lua` 统一历史、追更、缓存和统计列表；菜单只编排。
- `fanqie/reading_session.lua`：页位置采集、一次性返回栈、阅读时长与恢复决策。旧 `pending_progress` 继续是上传兼容队列，新资料库是本地事实源，二者不得相互覆盖为旧值。

持久化采用版本化 JSON 写临时文件后原子替换；单文件保存资料库、下载缓存仍留在用户目录。设置键仅放偏好；大列表按书或按类型拆分，避免每页重写全部记录。

## 4. GitNexus Findings

- `query(search_query="bookshelf refresh catalog chapters download cache management")` 定位到 `bookshelf.lua`、`download.lua`、`content.lua`、`chapter_actions.lua`；索引没有 execution flows，不能把文件相关当成调用关系。
- `query(search_query="reading progress sync catalog navigation statistics history")` 定位到开书、阅读、状态与统计模块；后续源码确认 `openBook` 和 `_refreshCatalogInBackground` 是冲突/历史的主要插入点。
- `query(search_query="settings persistence import export backup file storage")` 定位 `settings.lua`、`helper.lua`、`updater_ui.lua`；源码确认可复用 JSON、无外部 `unzip` 的归档解压与 Wi-Fi 检测模式。
- `impact(target="openBook", direction="upstream", maxDepth=3)` 返回 target not found / `risk: UNKNOWN`，不是“无调用方”。`context/PDG` 对 Lua 方法名同样未解析；文件锚定 PDG 为零条。结论：本计划不依赖空调用图，实际改动前须从上述源码入口逐一做文本调用核对与 `impact(file_path=...)`；新功能尽量新增模块，现有函数只做小编排改动。
- [verified] 已存在测试为 `tests/refactor_smoke.lua` 和 `tests/free_globals.lua`，当前均运行通过；`TESTCASES.md` 是真机/本机手工回归清单。

## 5. Statement-Level PDG Findings

已生成 PDG 层，但 Lua 方法目标无法解析，`pdg_query(mode="controls", target="fanqie/opening/open_book_actions.lua")` 返回空结果，因此不声称任何语句级图边。以源码确认的顺序约束替代：

1. 本地位置在发起上传时先入队，成功才删除；历史采集不得移除或重排这条链。
2. 切章会先更新章索引再关闭旧文档；页位置必须从旧文档路径反查 `item_id`，不得直接采用新章索引。
3. 后台目录更新只能尾部追加活动目录；搜索和追更不能用整体替换破坏这一不变量。
4. `ReaderReady` 才是文档就绪点；恢复页位置、启动计时/刷新界面应在这里或其后执行，取消/失败不得遗留计时器。
5. 清理缓存必须避开当前文档与活动下载；所有索引更新在文件删除成功后进行，失败保留旧索引。

## 6. Proposed Changes

### 6.1 统一资料库和偏好（基础）

- 新建 `library.lua`：`record_position` 保存 `book_id,item_id,chapter_index,page,total_pages,chapter_progress,updated_at,title,author`；`recent` 去重回流；`catalog_observation` 保存目录 ID 有序快照、最新章 ID、总章数、连载状态、检查时间与已确认最新章；`cache_observation` 保存章数、字节、更新时间。数字 ID 全程字符串。
- 老用户首次启动从待传队列、当前会话/书架缓存和磁盘目录迁移最近位置/缓存信息；无法确认页号时不猜，保留章级位置。写入节流（例如 15 秒且关闭时强制 flush），坏文件保留 `.corrupt` 并以空库恢复，不删除正文缓存。
- `settings.lua` 只增 `updates`, `offline`, `history`, `backup` 偏好和资料库 schema 版本；不引入凭证迁移。

### 6.2 追更中心

- `update_center.refresh` 基于非空云端书架快照，串行/小并发拉每书目录，和上次**成功**快照按 item ID 比较，记录 `unread_count=max(latest_index-last_read_index,0)`、`new_since_seen`、更新时间。首轮只建立基线，不把全书标为新增。
- 提醒分应用内徽标和可选系统通知（仅 KOReader `Notification` 可用且用户开启时），默认静默；每次启动/回到书架按间隔检查，阅读中仅不打扰地更新数据。无网、接口失败、空响应保留上次结果。
- 书架菜单提供“追更中心”及“全部/有更新/连载中”过滤，列表/网格都显示“未读 N · 新增 M”。支持单书/全部标记已读，标记只清提醒，不伪改阅读进度。
- “下载全部更新”生成跨书任务队列，复用 `Download.execute` 的章节获取、节流、缓存跳过、取消和结果统计；逐书串行，网络中断后保留待处理队列，不主动开 Wi-Fi。

### 6.3 缓存与离线管理

- `cache_manager.inventory` 递归统计每书目录中 HTML、图片、目录和索引，与资料库/书架/目录书名关联；显示总占用、已缓存/总章数、最近更新与完读状态。
- 单书清理先列范围：仅正文图片、指定章、已读完章或整本；保护当前打开章及待读队列。删除后同步 `Content.save_cache_index`、资料库统计和相关界面，不能让 `Content.load_cache_index` 内存副本复活已删项。
- 自动清理默认关闭；可选“仅保留已读书最后 N 章”或按缓存上限回收最久未读，永不自动清当前书未读章。离线模式只抑制插件后台网络任务，不改 KOReader 全局网络设置；已缓存书、目录、历史、统计仍完整可用。
- 追更书 Wi-Fi 自动预下载默认关闭，复用已连网检测和下载节流，下载数量/空间上限明确可见。

### 6.4 历史、恢复与冲突

- 菜单和书架增加“最近阅读”，包括未加入书架的书；点击按 item ID 定位，目录缺失时提示并可刷新，不按陈旧章号猜测。
- 页位置在 `ReaderReady` 后、节流翻页时、关闭文档时记录；历史恢复页优先于服务器章级进度。只读历史无元数据时从本地目录/缓存补全，不在菜单构建时联网。
- 打开书时构造本地/云端两个候选，显示章节名、章内百分比、更新时间，按钮“继续本地 / 使用云端 / 取消”。同章不同页或不同章均算差异；只有 `sync.ask_on_conflict` 开启才询问，关闭时维持现有较后位置策略。
- 选择云端后打开指定位置，不删除本地历史；随后正常上传覆盖云端。选择本地则保留并上传本地位置；用户未选择/超时/离线不覆盖任何候选。后台刷新只记录冲突，不在阅读中弹窗或自动跳章。

### 6.5 目录搜索与返回

- 扩展 `showChapterListing`：操作菜单新增“搜索章节”“跳转章节号”，关键字采用字面、大小写不敏感匹配；空关键词恢复完整目录，无结果保留可重搜/清除入口。
- 结果仍保留原章节对象和索引，缓存/当前标记一致；1500+ 章搜索只在用户提交时执行，不逐键联网或重建 HTML。
- 跳章前保存一个会话级返回位置 `{book_id,item_id,page}`；“返回刚才位置”通过现有导航打开并用 `after_navigate` 在文档就绪后恢复页码。只保留一层，连续跳转以最新一次为准；跨书/关闭阅读后清空。

### 6.6 进度与统计

- 阅读菜单“阅读统计”展示本章 `page/total_pages`、剩余页、章内百分比、全书 `chapter_index/total_chapters` 和按 `(chapter_index-1+chapter_progress)/total` 计算的百分比。章数未知显示“未知”，绝不产生 >100%。
- 预计时间按本书近期有效阅读页的滚动中位数估算；样本不足显示“暂无法估计”，前台无翻页不计时。
- 按书页聚合累计阅读时长、最近阅读、已读位置；优先读取 KOReader 已合并的 `statistics.sqlite3`，库不可用时使用本地会话时长，明确标注口径。统计导出仅汇总，不包含正文。

### 6.7 本地备份与恢复

- 新 `backup.lua` 生成版本化 ZIP：manifest（格式/插件版本/时间/内容选项与 SHA-256）、脱敏偏好、资料库、统计汇总，可选完整书籍缓存目录。文件名含时间，用户选保存位置；默认不含缓存。
- 永不导出 `config.lua`、Cookie、设备池、设备身份、`reading_v1_key`、日志、更新器备份。采用字段白名单而非仅删若干已知敏感键，并测试嵌套凭证也不进入包。
- 导入先校验路径、ZIP 条目无绝对路径/`..`/链接、manifest/schema/大小和每项摘要；展示内容、时间、覆盖范围及所需空间。先完整解到临时目录，校验通过后为用户现有数据创建本地回滚点，再原子替换；失败/取消不动现有数据。
- 恢复后重建运行时缓存和统计内存，要求重启提示；不回灌 `download_dir` 到不同设备，正文按 manifest 的原相对路径重定位。不把备份用于跨设备自动合并，导入是明确确认后的替换。

## 7. Implementation Sequence

1. **资料库与测试基座**：实现版本化存储、旧状态迁移、缓存/目录/位置采集；新增纯 Lua 单元 harness。保持默认阅读行为不变。
2. **历史与冲突**：接入最近阅读、页恢复、冲突对话框，先解决“位置可信”，供未读计算和返回栈共用。风险：旧文档/新章错位，必须覆盖切章与冷启动续读。
3. **目录搜索与返回**：扩展目录 UI 和就绪后页恢复，离线验证大目录与无结果路径。
4. **追更中心**：实现快照、更新筛选、提醒与跨书下载队列。风险：请求量与活动目录错位；默认串行、可取消且保留现有节流。
5. **缓存/离线管理**：清单、保护性清理、自动维护与离线模式。风险：误删当前章/索引陈旧；清理必须真机断网回归。
6. **进度与统计页**：接入本章/全书指标与按书时长，保持已有虚拟页统计口径。
7. **备份恢复**：最后接入稳定的数据格式；完成恶意 ZIP、空间不足、损坏/取消和不同缓存根目录测试。
8. **文档和总回归**：一次性更新 README、`TESTCASES.md`、示例偏好；每阶段单独可发布，不将六项压成一次不可回滚大改。

## 8. Test Strategy

- 新增 `tests/library_spec.lua`：ID 精度、去重/排序、写入中断恢复、旧 pending 迁移、相同 item 的页位置不被章号覆盖。
- 新增 `tests/update_center_spec.lua`：首轮基线、尾部新增、目录插入/删章、空响应/失败不毁快照、未读与标记已读、跨书队列取消/续作。
- 新增 `tests/cache_manager_spec.lua`：中文/自定义缓存根、漫画图片递归大小、当前章保护、部分删除失败、删除后内存索引不可复活。
- 新增 `tests/reading_session_spec.lua`：本地/云端同章异页、不同章、取消、关闭冲突询问、后台不弹窗；跳转返回在 ReaderReady 后恢复且跨书清空。
- 新增 `tests/catalog_spec.lua`：1500 章、特殊字符、空结果、重复标题、原 item ID 不变；`tests/stats_spec.lua` 覆盖未知章数、不足样本、时长聚合和不超 100%。
- 新增 `tests/backup_spec.lua`：往返恢复、脱敏白名单、摘要/schema 错误、路径穿越/链接/超限、空间不足与导入取消零修改。
- 更新 `tests/refactor_smoke.lua`、`tests/expected_methods.txt` 覆盖新入口；每阶段运行 `luajit tests/refactor_smoke.lua .` 和 `luajit tests/free_globals.lua .`（已验证存在且当前通过）。
- `TESTCASES.md` 增六组 P0/P1 真机用例：Wi-Fi 开关不自动打开、冷启动续读、1500 章、漫画大缓存、下载中清理拦截、手机与 KOReader 交替阅读、备份到另一缓存根。

## 9. Risk and Impact Analysis

- **位置回归（高）**：现有切章/关文档顺序敏感。所有恢复按 item ID，页恢复只在 ReaderReady 后，冲突选择不自动覆盖历史。
- **误删缓存（高）**：保护当前文档/下载队列，二次确认，先做选择性删除再开放自动策略；失败不更新索引。
- **备份安全（高）**：白名单脱敏、归档限制、摘要和临时目录校验；不向网络发送备份。
- **请求/电量（中）**：追更串行、小批量、频率限制，自动功能默认不弹提醒不自动下载，复用下载节流。
- **磁盘/内存（中）**：资料库分文件、翻页写盘节流；大目录只按提交搜索；备份前预估空间，漫画可能很大。
- **统计口径（中）**：不修改 CHAPTER_SPAN 映射；未知章数降级显示，时长来源明确。
- **图依赖限制**：当前图未解析 Lua 方法，`UNKNOWN` 不视作安全；每个实施步骤先对具体文件/符号做 impact + 文本核对，并在提交前运行完整 `detect_changes`。

## 10. Files Expected to Change

| File | Symbols | Reason |
| ---- | ------- | ------ |
| `fanqie/library.lua`（新） | 存储、迁移、位置/快照 | 六项共用事实源 |
| `fanqie/update_center.lua`、`cache_manager.lua`、`reading_session.lua`、`backup.lua`（新） | 领域操作 | 避免继续膨胀编排层 |
| `fanqie/library_view.lua`（新） | 列表/统计/确认 UI | 统一入口与墨水屏交互 |
| `fanqie/settings.lua` | defaults、偏好 | 新设置与 schema |
| `fanqie/opening/open_book_actions.lua` | `openBook`、`_openBookWithCache`、`_refreshCatalogInBackground` | 恢复、冲突与目录观察 |
| `fanqie/reader/reader_actions.lua` | `syncCurrentProgress`、`onPageUpdate`、`onCloseDocument` | 位置/时长采集，不改上传顺序 |
| `main.lua` | `onReaderReady`、菜单挂载 | 恢复位置和新模块入口 |
| `fanqie/chapters/chapter_actions.lua` | `showChapterListing`、`navigateToChapter` | 搜索、返回栈 |
| `fanqie/bookshelf.lua`、`shelf_view.lua`、`shelf/shelf_actions.lua` | 刷新、过滤、列表标记 | 追更/历史/缓存入口 |
| `fanqie/download.lua`、`content.lua` | 队列回调、索引同步 | 批量更新与安全清理 |
| `fanqie/stats.lua`、`menus/menu_actions.lua` | 聚合查询、设置 | 统计与功能偏好 |
| `tests/*`、`TESTCASES.md`、`README.md` | 新回归 | 自动化和真机验收 |

## 11. Reusable Implementation Context

```yaml
implementation_context:
  task_summary: "以统一本地资料库为基础，分七阶段交付追更、缓存离线、历史冲突、目录导航、统计和无凭证备份。"
  acceptance_criteria:
    - "六项均有菜单入口、离线退化和异常路径，不覆盖现有阅读/进度正确性"
    - "历史记录页级位置；冲突可选且取消无副作用；追更按 item ID 且未读可信"
    - "缓存清理有保护和索引同步；备份不含凭证并可失败回滚"
    - "自动化与真机核心回归通过，更新 TESTCASES/README"
  evidence_provenance:
    schema_version: 2
    head_commit: "52b12ca7518ff42449a266d4cc57a1bdc78d003b"
    generated_plan_path: "docs/plans/2026-10-27-gitnexus-plan-reading-library-enhancements.md"
    global_dirty_digest:
      algorithm: "sha256"
      canonicalization: "gitnexus-evidence-provenance-v2 NUL-framed UTF-8 records"
      value: "28bbd7e6e48febfaa8ac5f4dc78b521d2cdcb8c4cb8b68fda32fd3e2d22b46df"
    cited_path_manifest:
      - {path: "TESTCASES.md", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:bce2bd3ff1fef4edae9eaa8de1626e98e11c9d8c8632044c8fc304f1f07ed27c", index_digest: "sha256:bce2bd3ff1fef4edae9eaa8de1626e98e11c9d8c8632044c8fc304f1f07ed27c", worktree_digest: "sha256:bce2bd3ff1fef4edae9eaa8de1626e98e11c9d8c8632044c8fc304f1f07ed27c", untracked_digest: absent}
      - {path: "fanqie/bookshelf.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:c16d42b1a4317fbcd97901ab562a0f1984684a32ac477a03c96ea32337bcb109", index_digest: "sha256:c16d42b1a4317fbcd97901ab562a0f1984684a32ac477a03c96ea32337bcb109", worktree_digest: "sha256:c16d42b1a4317fbcd97901ab562a0f1984684a32ac477a03c96ea32337bcb109", untracked_digest: absent}
      - {path: "fanqie/chapters/chapter_actions.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:716dbc84dd92d8468b642d46f60fb3b5b74d5ee0e1d0d15d5a91db52ead4fa31", index_digest: "sha256:716dbc84dd92d8468b642d46f60fb3b5b74d5ee0e1d0d15d5a91db52ead4fa31", worktree_digest: "sha256:716dbc84dd92d8468b642d46f60fb3b5b74d5ee0e1d0d15d5a91db52ead4fa31", untracked_digest: absent}
      - {path: "fanqie/client.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:9daaf51c996b104e4cf6cdfd979e36bac30fa1ed0db8f171d5bb53b6799ba1c6", index_digest: "sha256:9daaf51c996b104e4cf6cdfd979e36bac30fa1ed0db8f171d5bb53b6799ba1c6", worktree_digest: "sha256:9daaf51c996b104e4cf6cdfd979e36bac30fa1ed0db8f171d5bb53b6799ba1c6", untracked_digest: absent}
      - {path: "fanqie/content.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:7233cca5d461ac006ddc3c353b22ace58fff46ba0a1a5416ea151f43de04a97f", index_digest: "sha256:7233cca5d461ac006ddc3c353b22ace58fff46ba0a1a5416ea151f43de04a97f", worktree_digest: "sha256:7233cca5d461ac006ddc3c353b22ace58fff46ba0a1a5416ea151f43de04a97f", untracked_digest: absent}
      - {path: "fanqie/download.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:51edeb1dfcedae5f617f0daf78bd1799fad047b1d55387c7fffc6d7089ad113d", index_digest: "sha256:51edeb1dfcedae5f617f0daf78bd1799fad047b1d55387c7fffc6d7089ad113d", worktree_digest: "sha256:51edeb1dfcedae5f617f0daf78bd1799fad047b1d55387c7fffc6d7089ad113d", untracked_digest: absent}
      - {path: "fanqie/helper.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:92ee9e527a53ac3276e5154febb0035ac4e16f6bae7e50b40b0ca386ba06d38c", index_digest: "sha256:92ee9e527a53ac3276e5154febb0035ac4e16f6bae7e50b40b0ca386ba06d38c", worktree_digest: "sha256:92ee9e527a53ac3276e5154febb0035ac4e16f6bae7e50b40b0ca386ba06d38c", untracked_digest: absent}
      - {path: "fanqie/menus/menu_actions.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:cc2492a0fc1deabbedfb313ffeaeeab7abb01d17c8b1025eb6ce2de0d247da9f", index_digest: "sha256:cc2492a0fc1deabbedfb313ffeaeeab7abb01d17c8b1025eb6ce2de0d247da9f", worktree_digest: "sha256:cc2492a0fc1deabbedfb313ffeaeeab7abb01d17c8b1025eb6ce2de0d247da9f", untracked_digest: absent}
      - {path: "fanqie/opening/open_book_actions.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:6683aed478f94c8eea14f51b941748f536bc83758410b00b86f5509cdeae1f37", index_digest: "sha256:6683aed478f94c8eea14f51b941748f536bc83758410b00b86f5509cdeae1f37", worktree_digest: "sha256:6683aed478f94c8eea14f51b941748f536bc83758410b00b86f5509cdeae1f37", untracked_digest: absent}
      - {path: "fanqie/reader/reader_actions.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:4b4668269202fd27c824bd977365cf9c9b2efb9348b4aad4686d59bf24ce66f4", index_digest: "sha256:4b4668269202fd27c824bd977365cf9c9b2efb9348b4aad4686d59bf24ce66f4", worktree_digest: "sha256:4b4668269202fd27c824bd977365cf9c9b2efb9348b4aad4686d59bf24ce66f4", untracked_digest: absent}
      - {path: "fanqie/settings.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:0bb15f68bc14b6119ee79a356a5bd26079c86568ea13c2c646605481ef89f2ff", index_digest: "sha256:0bb15f68bc14b6119ee79a356a5bd26079c86568ea13c2c646605481ef89f2ff", worktree_digest: "sha256:0bb15f68bc14b6119ee79a356a5bd26079c86568ea13c2c646605481ef89f2ff", untracked_digest: absent}
      - {path: "fanqie/shelf/shelf_actions.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:b7fac0aad962231c172cfdfe2d93db443a2bf3a5264175ad7b4724e3660e2b57", index_digest: "sha256:b7fac0aad962231c172cfdfe2d93db443a2bf3a5264175ad7b4724e3660e2b57", worktree_digest: "sha256:b7fac0aad962231c172cfdfe2d93db443a2bf3a5264175ad7b4724e3660e2b57", untracked_digest: absent}
      - {path: "fanqie/shelf_view.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:8cce95bf1fcb1cd205b8354844bff35902da4e253ceb2f79ca883b0f20316eec", index_digest: "sha256:8cce95bf1fcb1cd205b8354844bff35902da4e253ceb2f79ca883b0f20316eec", worktree_digest: "sha256:8cce95bf1fcb1cd205b8354844bff35902da4e253ceb2f79ca883b0f20316eec", untracked_digest: absent}
      - {path: "fanqie/state.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:876867e9cad7dd0cc61d7e5ffc6eb619d76f04271bd1c3ee72b6d6fba8072b91", index_digest: "sha256:876867e9cad7dd0cc61d7e5ffc6eb619d76f04271bd1c3ee72b6d6fba8072b91", worktree_digest: "sha256:876867e9cad7dd0cc61d7e5ffc6eb619d76f04271bd1c3ee72b6d6fba8072b91", untracked_digest: absent}
      - {path: "fanqie/stats.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:1764b55fb13642f632b10be94c3eea9e76654a4e2892ae4311362cda8a454bcc", index_digest: "sha256:1764b55fb13642f632b10be94c3eea9e76654a4e2892ae4311362cda8a454bcc", worktree_digest: "sha256:1764b55fb13642f632b10be94c3eea9e76654a4e2892ae4311362cda8a454bcc", untracked_digest: absent}
      - {path: "fanqie/updater_ui.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:4094ba4c563e1065f5b7ca61358277603170507cbba03cd2dabd5065edba0ab9", index_digest: "sha256:4094ba4c563e1065f5b7ca61358277603170507cbba03cd2dabd5065edba0ab9", worktree_digest: "sha256:4094ba4c563e1065f5b7ca61358277603170507cbba03cd2dabd5065edba0ab9", untracked_digest: absent}
      - {path: "main.lua", object_kind: {head: regular, index: regular, worktree: regular, untracked: absent}, state: clean, rename_from: null, rename_to: null, head_digest: "sha256:f0e86929832fc10b372dbed07936382b0bef7669732ebd7666076857a9fe56d7", index_digest: "sha256:f0e86929832fc10b372dbed07936382b0bef7669732ebd7666076857a9fe56d7", worktree_digest: "sha256:f0e86929832fc10b372dbed07936382b0bef7669732ebd7666076857a9fe56d7", untracked_digest: absent}
      - {path: "tests/free_globals.lua", object_kind: {head: absent, index: absent, worktree: absent, untracked: regular}, state: untracked, rename_from: null, rename_to: null, head_digest: absent, index_digest: absent, worktree_digest: absent, untracked_digest: "sha256:b2f52edb78982a9ec3473a2bd1489ae65ab5541a258c86950fd068485d20a8da"}
      - {path: "tests/refactor_smoke.lua", object_kind: {head: absent, index: absent, worktree: absent, untracked: regular}, state: untracked, rename_from: null, rename_to: null, head_digest: absent, index_digest: absent, worktree_digest: absent, untracked_digest: "sha256:899c5493c6ae143d8452078a39a24c05dbd64291a39670a37819b84e656624cf"}
  primary_symbols:
    - {symbol: "openBook / _refreshCatalogInBackground", file: "fanqie/opening/open_book_actions.lua", lines: "72-330", role: "恢复决策、目录观察"}
    - {symbol: "showChapterListing / navigateToChapter", file: "fanqie/chapters/chapter_actions.lua", lines: "38-292,318-458", role: "目录搜索和返回"}
    - {symbol: "onReaderReady", file: "main.lua", lines: "206-243", role: "文档就绪后的恢复/统计"}
    - {symbol: "Settings:get_cache_stats / clear_book_cache", file: "fanqie/settings.lua", lines: "576-667", role: "扩展现有缓存管理"}
    - {symbol: "Stats.resolve / virtual_page", file: "fanqie/stats.lua", lines: "177-255", role: "按书统计口径"}
  related_symbols:
    - {symbol: "Download.execute", relationship: "reuse", relevance: "更新下载复用节流/取消"}
    - {symbol: "State.addPendingProgress", relationship: "reuse", relevance: "兼容上传队列，非新历史替代"}
    - {symbol: "Content.save_cache_index", relationship: "CALLS", relevance: "清理后同步内存与文件"}
    - {symbol: "Client:update_read_progress", relationship: "CALLS", relevance: "冲突选择后正常上传"}
  execution_path:
    - "开书读本地目录/资料库 -> 异步拉云端目录/进度 -> 候选冲突决策 -> 打开 item -> ReaderReady 恢复页"
    - "书架刷新 -> 追更检查 -> 快照/徽标 -> 用户筛选或排队下载"
    - "阅读翻页 -> 节流记录位置/时长 -> 关闭强制保存 -> 上传队列独立补传"
    - "备份导出白名单 -> 临时包/摘要 -> 导入校验 -> 回滚点 -> 原子替换"
  pdg_constraints:
    - {description: "PDG 已生成但 Lua 方法/文件切片无结果；以下顺序由源码验证", affected_statements: ["fanqie/reader/reader_actions.lua:274-291", "fanqie/opening/open_book_actions.lua:131-157", "main.lua:210-243"], implementation_consequence: "先记位置/按 item 切章/只在 ReaderReady 恢复；不可从空 PDG 推断无依赖"}
  architectural_patterns:
    - {pattern: "异步网络，失败保留缓存", example_location: "fanqie/bookshelf.lua:296-342", usage_guidance: "追更与冲突不可阻塞 UI 或用空响应清库"}
    - {pattern: "ID 字符串化与文档路径归属", example_location: "fanqie/opening/open_book_actions.lua:119-138", usage_guidance: "禁止以全局 current_book 代替文档归属"}
    - {pattern: "不依赖系统解压/Wi-Fi 不主动开启", example_location: "fanqie/helper.lua:197-207", usage_guidance: "备份跨 Kindle/Kobo 可用"}
  files_to_modify:
    - {file: "fanqie/library.lua", symbols: ["new"], intended_change: "版本化本地事实源和迁移"}
    - {file: "fanqie/opening/open_book_actions.lua", symbols: ["openBook", "_refreshCatalogInBackground"], intended_change: "冲突选择/目录观察"}
    - {file: "fanqie/chapters/chapter_actions.lua", symbols: ["showChapterListing", "navigateToChapter"], intended_change: "搜索和返回位置"}
    - {file: "fanqie/reader/reader_actions.lua", symbols: ["onPageUpdate", "onCloseDocument"], intended_change: "页位置与时长采集"}
    - {file: "main.lua", symbols: ["onReaderReady", "init"], intended_change: "恢复/新入口"}
    - {file: "新增 update_center/cache_manager/backup/library_view", symbols: ["new"], intended_change: "各自完整功能"}
  tests:
    - {file: "tests/library_spec.lua", scenarios: ["迁移/重启/损坏文件 -> 保留可用记录", "19 位 ID -> 不截断"]}
    - {file: "tests/reading_session_spec.lua", scenarios: ["冲突取消 -> 不覆盖", "跳章 -> 返回原 item+page"]}
    - {file: "tests/update_center_spec.lua", scenarios: ["新章 -> 未读增加", "空响应 -> 快照保留"]}
    - {file: "tests/cache_manager_spec.lua", scenarios: ["当前章清理 -> 拒绝", "删除成功 -> 索引/统计同步"]}
    - {file: "tests/backup_spec.lua", scenarios: ["恶意路径/摘要坏 -> 零修改", "往返 -> 无凭证且数据恢复"]}
    - {file: "TESTCASES.md", scenarios: ["真机六功能 P0/P1 和离线/漫画/跨设备"]}
  verification_commands:
    - "luajit tests/refactor_smoke.lua ."
    - "luajit tests/free_globals.lua ."
    - "luajit tests/library_spec.lua ."
    - "luajit tests/reading_session_spec.lua ."
    - "luajit tests/update_center_spec.lua ."
    - "luajit tests/cache_manager_spec.lua ."
    - "luajit tests/backup_spec.lua ."
  risks: ["进度错章/错页", "误删活动缓存", "追更请求量", "备份泄密/路径穿越", "统计双口径"]
  assumptions:
    - "系统通知能力取决于 KOReader 当前版本；实现前检查 Notification，不支持则仅应用内提醒。"
    - "云端进度响应的页级字段尚未核实；无页级值时只比较/显示章级并保留本地页。"
    - "跨设备恢复只针对显式备份包，不自动合并两台设备的阅读历史。"
  open_questions:
    - "系统通知是否必须在后台进程也送达？当前规划仅保证插件运行时/应用内提醒。"
    - "是否需要正文随备份默认打包？当前默认否，以控制包大小。"
  avoid:
    - "不要把 UNKNOWN 的图结果当成无调用方；改现有函数前补文件 impact 和文本调用核对"
    - "不要改变现有 pending 上传、活动目录尾部追加或虚拟页统计不变量"
    - "不要导出 config.lua、Cookie、设备身份、密钥或日志"
    - "不要在后台刷新中弹冲突框/自动跳章，不要主动打开 Wi-Fi"
```

## 12. Assumptions and Open Questions

- [assumed] KOReader 系统通知接口在目标设备可用；不支持时明确显示“仅应用内提醒”，不伪造已通知。
- [assumed] 云端接口的页级进度字段需在实施时以真实响应核实；没有时云端仅提供章级候选。
- 默认不自动下载、不自动清理、不弹系统通知，用户可逐项开启；追更检查本身启用。
- 本轮不扩展第三方账号、云备份、全文内容搜索、书源或界面主题，避免超出六项范围。

## 13. Definition of Done

1. 六项功能均可从菜单到达，空数据、无网络、接口失败、取消时有明确且非破坏性的行为。
2. 历史保留精确 item/page，冲突有双向选择；切章、冷启动、自动下一章与上传回归无错章错页。
3. 追更只将真实新章计为更新，未读与提醒可独立清除；批量下载可取消、可恢复并遵守节流。
4. 缓存清单与实际占用一致，清理保护活动章节且索引同步；离线模式不主动开 Wi-Fi。
5. 目录搜索/章号/返回原位支持大目录；进度与统计不超 100%，未知数据不伪造估算。
6. 备份通过脱敏、路径、摘要和失败回滚测试，能在不同缓存根恢复；不包含任何凭证。
7. 所有新增/现有自动化通过，真机 P0/P1 结果写入 `TESTCASES.md`；每阶段实施提交前 `detect_changes` 无未解释影响。
