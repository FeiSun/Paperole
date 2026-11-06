# final.pdf 的摘要页：改成一张待办表（设计稿，2026-11-05，11-06 补充）

**2026-11-06 已实现方案 B**（你选的）：引擎 `render.py` 的摘要页、`final_preview` 调用，app 的 Finish 框（左边卡片，右边预览）。规则以 `engine/CONTRACT.md` 修正案 "Summary page as a to-do sheet" 和 `mac/UX.md` §45 为准；这里的样稿是设计时的样子。

- 样稿：`make_mockup.py` 用引擎自己的绘图函数（`paperole.render`）画出摘要页，数据是合成的（`samples/promo-demo` 的一份拷贝，Round 2 给了判定后完成；"条数多"的那版在内存里再加 62 条编出来的新批注）。`make_sheet.py` 用 `design/stats-card/src/build.py` 的卡片和控件画 Finish 框。
- 图：`png/before.png` 今天；`png/mockup-a.png`、`mockup-b.png` 条数少；`mockup-c.png`、`mockup-c-2.png` 条数多；`finish-sheet-light.png`、`finish-sheet-dark.png` Finish 框。对照页：`compare.html`。
- 重新生成：`engine/.venv/bin/python design/summary-page/make_mockup.py <评审拷贝> <输出>`，再 `engine/.venv/bin/python design/summary-page/make_sheet.py <输出>/mockup-b.pdf <评审拷贝> <snapsvg> <输出>`（`snapsvg` 用 `swiftc -O design/logo/final/src/snapsvg.swift -o …` 编译）。

## 1. 一段话

摘要页只回答学生的三个问题：**还要做几件事、在哪里、各是什么**。最上面一个大数字（朱红，"5 to do of 16 comments"）和一条进度条（11 closed · 3 again · 2 new：again 就是上一轮没改好的，条数多时同名的组放在最前面）；然后是这轮主要问题的标签计数（Main issues: Clarity 13 · Grammar 12 …，待办至少 6 条且有标签出现 2 次以上才显示，最多 5 个）；然后是你的 **Overall** 意见（全文，见 6a），再是**待办表**，每条一行：颜色条（和论文里这条批注的标记同色）、ID 小签（带状态符号）、状态词、页码、节号、批注要求的第一行（截断，全文在页边）、标签。表按论文顺序排，学生从头往后改。下面是已关闭的（只有 ID 小签，不重复内容；夸奖算在 Resolved 里，和 round 卡片的数字一致，另起一行 "Well done" 引用你的原话和页码）、学生自己的其他修改、最后一行 Build 和论文里标记的图例。方案 B 在待办表上方多一条**页面缩略图**：有待办的页加黑框，红点是待办的位置，灰点是已关闭的，点一页就跳过去。

## 2. 和今天比

| | 今天 | 提议 | 为什么 |
|---|---|---|---|
| 待办 ID | 在 How to reply 框里列一次，下面分组又列一次 | 只在待办表里一次 | 同一件事只说一次 |
| 分组 | 按状态分 Follow-ups / Still open / No change needed / Resolved / New，学生要在几组之间来回看 | 一张表按论文顺序；状态是每行的一个词 | 学生按页改论文 |
| Key 图例 | 一整行符号 + 一句 "each comment's mark keeps the colour…" | 状态写成词，不需要图例；颜色条直接放在行首 | 去掉解释文字 |
| 已关闭 | 有备注的占一整行 | 只有 ID 小签；内容在页边 | 不重复 |
| 数字 | 分散在各组标题里 | 顶部一个大数字 + 进度条 + 标签计数 | 一眼看到工作量和进展；保留所有客观数据 |
| 位置 | 只有页码 | 页码 + 节号（来自 prose.json）；方案 B 还有缩略图 | "§4.1" 比 "p.4" 更好找 |
| 页码说明 | "page numbers are the paper's (the summary comes before its page 1)" | 去掉（PDF 的页面标签已经是论文的页码） | 少一句话 |
| How to reply | 浅蓝框，在最前面 | 一段灰字，紧跟在待办表下面 | 回复规则属于"怎么做"，放在任务旁边 |

## 3. 借鉴

- **Linear / Things 的列表**：一行一件事，状态在左、元信息靠右、发丝线分隔，不用卡片。
- **Stripe 收据**：列对齐、数字用粗体、留白多，整页像一张单据。
- **GitHub 代码评审**："3 unresolved conversations"，已解决的折叠成一行。
- **VS Code 滚动条上的标记 / Paperole 自己的论文地图**：方案 B 的缩略图条。
- **Grammarly 的写作报告**：按类别计数，对应你说的 "main issues this round"。

## 4. 要不要用 AI

建议第一版**不用**，理由：

1. 批注本来就是你写的短句，第一句通常就是要求，"第一行 + 页码 + 节号 + 标签"已经够当任务名。
2. 整篇论文的总结应该是你自己的话：Overall 批注（另一个 session 已经做好）放在摘要页最上面，这比 AI 写的更有分量。样稿的演示论文没有 Overall 批注，所以图里没有这一段。
3. API key 会把学生的论文发给外部服务，和"论文不出本机"的规则冲突；结果不确定，每轮都得你再检查一遍；还要设置页、费用、出错处理。

以后如果要加，合适的位置是 **app 里"起草 Overall 批注"**：AI 给一段草稿，你改完再存，PDF 里永远是你确认过的文字，生成仍然是确定的。另一个不出本机的选择是 macOS 26 的本地模型（Foundation Models），等你的 Mac 升级后再考虑。

## 5. 条数多的时候（新手初稿）

一条一行在 60–100 条时会变成三四页清单，抓不住重点。所以待办表**自动切换**：

- **不超过 20 行**（小改动合并后）：一条一行，按论文顺序。
- **超过 20 行：按节分组**。左栏是节名、"15 on pp.3–5"、这节最多的两个标签（5 条以上才写）；右栏是这节所有批注的 ID 小签，自动换行，每个都能点到页边的全文。顺序：Abstract、§1、§2 …、附录。
- **Again**（follow-up 和 still open，上一轮没改好的）永远放在最前面，一条一行写出要求。
- **Small fixes**：标签全是 Grammar、Wording 或 Format 的批注，至少 3 条时合成一行小签，两种排法都用。
- 样稿 C：67 条待办，第一页放下了全部待办，第二页是已关闭、其他修改和 Build。

## 6. Finish 框：预览 + round 卡片

- 框从 920 × 640 放大到 1120 × 760，预览按 98% 显示，字和 PDF 里差不多大。
- **左栏**：Left for you（还剩什么，和今天一样），下面是 round 卡片 "Round 2 so far"（保留，实时更新）。
- **右栏**："final.pdf · the student’s first page"，学生收到的第一页，实时生成到缓存，可以滚动。指针停在一行上，那一行浅 Sage 底，提示 "Show R1-05 in the paper"；点一下关掉框、选中这条批注。改完再点 Finish Round…，预览已经更新。
- 去掉今天的 **Goes to the student** 计数（预览里都有）。**Words not sent yet**（没发出的草稿）照旧，有草稿时在 Left for you 下面。
- 点 Finish Round 后，框照旧变成完整的 round 卡片。
- 预览需要引擎新增一个只生成摘要页、写到缓存的调用，不写 `rN/`、不关闭这一轮。

## 6a. Overall 批注（整篇论文的意见）

app 里已经有（2026-11-05，`mac/UX.md` §44；引擎 27d0a90）：批注列表上方的 "+ Overall comment"，没有位置，只有文字，和别的批注一样可以 follow-up、resolve、打标签，下一轮会带过去。今天的 final.pdf 把它们完整写在摘要页的 Overall 段里，论文页上没有（页边放不下没有位置的批注），所以**摘要页是学生唯一能读到它的地方，必须完整、不截断**。

新设计里：

- **位置**：大数字和 Main issues 下面、缩略图和逐条待办上面。学生先看到工作量，再读你对整篇的看法，然后才是逐页的事。
- **样子**：每条一块：左边颜色条和 ID 小签（带状态符号），小签下面写状态词；右边是全文，10 pt，比待办行大一号，因为这是你的总体意见。follow-up 时你这一轮的话在前，上一轮的原话灰色在后（和页边的规则一样）。新的排在 follow-up 后面。
- **数字对得上**：Overall 的待办算在大数字里，所以两个标题都带个数：**Overall (2)** 和 **On the pages (5)**，加起来就是 "7 to do"。没有 Overall 批注时，表头照旧是 "To do for Round 3"。
- **条数多时**也一样：Overall 在最前面，下面是 "On the pages (67)"，里面先 Again，再按节分组。
- **已关闭的 Overall 批注**（resolved 或 no change needed）和别的已关闭批注一样，只在 Closed 里出一个小签。它在论文里没有位置，小签不链接任何地方。
- **Finish 框**：预览里就是这一页；round 卡片的数字也算上 Overall 批注（样稿：3 New、3 Followed up、"14 of 15 earlier comments answered"）。

同一次提交还有**一条批注多个位置**（目前只有引擎，app 还没有界面）：今天的摘要写 "p.1 ⇄ p.4"。新表里页码列照样写 "p.1 ⇄ p.4"，后面的文字往右让；缩略图在每个位置各画一个点。样稿里没有这种批注。

## 7. 已定（2026-11-06，按我的判断，你说"按你的经验来"）

- 待办按论文顺序；follow-up 和 still open 在条数多时放进最前面的 Again。
- 学生的其他修改每处一行。
- 标签计数：待办至少 6 条且至少一个标签出现 2 次以上才显示，最多 5 个。

## 8. 还要你决定

- **D1 缩略图条（方案 B）**：要不要？建议要：一眼看出工作集中在哪几页，点一下就跳过去；条数多时尤其有用。论文超过约 20 页时缩略图太小，改用 round 卡片那种小方块（只画标记，不画页面）。
