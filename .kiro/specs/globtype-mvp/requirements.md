# 需求文档：Globtype MVP

## 简介

Globtype 是一个 macOS 菜单栏工具，面向中文母语用户。用户在任意 App 的输入框中写完中文（或中英混写、中式英语）段落后，双击 Shift 唤出悬浮面板，面板中显示英文译文，确认后译文替换原文。每次被接受的翻译会自动记录到本地「表达库」，从中提取值得学习的英文表达进入间隔重复复习。

MVP 范围：
- 目标语言仅英语，单一翻译结果（不做多风格）
- 以整段文本翻译为主，同时支持选区翻译
- 纯开源（MIT），用户自带 API Key，无账号、无服务端，所有数据仅存本机
- 最低系统版本 macOS 15
- 不申请 Apple 开发者账号，使用固定的自签名证书分发

不在 MVP 范围：三风格改写、多目标语言、富文本格式保留、自动更新、Homebrew 分发、每周回顾、"先自己试"模式、数据导入导出、用户水平档位设置。

## 术语表

- **Globtype**：本产品，一个常驻菜单栏的 macOS 应用
- **目标输入框**：唤起时拥有键盘焦点的、其他 App 中的可编辑文本控件
- **源文本**：从目标输入框读取到、将被翻译的文本（选区或全文）
- **悬浮面板**：显示译文的浮动窗口，显示时不夺取目标 App 的键盘焦点
- **翻译服务商**：提供翻译能力的后端，包括 OpenAI 兼容 API、本地模型、Apple 翻译框架
- **表达库**：本地存储的全部已接受翻译的历史记录
- **表达**：从一次翻译中提取的、具有学习价值的英文短语、搭配或单词
- **复习卡片**：进入间隔重复调度的表达
- **组词状态**：中文输入法正在显示拼音候选、尚未上屏的状态（即存在 marked text）
- **安全输入**：密码框或系统 Secure Event Input 处于开启的状态
- **本地词典**：随 App 打包的 ECDICT 精简版英汉词典

## 需求

### 需求 1：全局唤起

**用户故事：** 作为用户，我希望在任何 App 中用双击 Shift 唤起翻译，这样不用离开当前输入框。

#### 验收标准

1. WHEN 用户在 400 毫秒内连续按下并松开 Shift 键两次，且两次之间没有按下其他任何键，THE Globtype SHALL 对当前目标输入框启动一次翻译。
2. WHEN 用户按住 Shift 键与其他键组合输入（例如输入大写字母），THE Globtype SHALL 不将其计为一次 Shift 单击。
3. WHILE 中文输入法处于组词状态，THE Globtype SHALL 忽略双击 Shift。
4. WHEN 双击 Shift 触发翻译，THE Globtype SHALL 保证触发后输入法的中英模式与触发前一致；IF 经实测某输入法无法满足此条件，THEN THE Globtype SHALL 在首次引导中建议该输入法的用户改用自定义快捷键。
5. WHERE 用户在设置中配置了自定义快捷键，THE Globtype SHALL 同时响应该快捷键启动翻译。
6. WHERE 当前前台 App 在用户的排除列表中，THE Globtype SHALL 忽略唤起操作。
7. THE Globtype SHALL 在首次安装时将 JetBrains 系列 IDE 预置在排除列表中。
8. WHEN 用户在菜单栏中关闭 Globtype，THE Globtype SHALL 停止响应所有唤起操作，直到用户重新开启。

### 需求 2：安全输入保护

**用户故事：** 作为用户，我希望 Globtype 永远不会读取我的密码，这样我可以放心授予它辅助功能权限。

#### 验收标准

1. IF 目标输入框是密码框（辅助功能子角色为 `AXSecureTextField`），THEN THE Globtype SHALL 不读取其内容并忽略本次唤起。
2. IF 系统安全输入处于开启状态，THEN THE Globtype SHALL 不读取任何文本并忽略本次唤起。
3. THE Globtype SHALL 不提供任何关闭需求 2 中保护行为的设置项。

### 需求 3：读取源文本

**用户故事：** 作为用户，我希望 Globtype 自动拿到我刚写的整段内容或选中部分，这样不用手动复制。

#### 验收标准

1. WHEN 翻译被触发且目标输入框中存在非空选区，THE Globtype SHALL 将选区文本作为源文本。
2. WHEN 翻译被触发且目标输入框中不存在选区，THE Globtype SHALL 将目标输入框的全部文本作为源文本。
3. THE Globtype SHALL 优先通过 macOS 辅助功能接口读取源文本。
4. WHEN 目标 App 基于 Electron 或 Chromium 且其辅助功能树未启用，THE Globtype SHALL 先为该 App 启用辅助功能树，再读取源文本。
5. IF 通过辅助功能接口无法读取源文本，THEN THE Globtype SHALL 通过模拟复制读取源文本，并在读取完成后将系统剪贴板恢复为读取前的内容。
6. IF 源文本为空或仅包含空白字符，THEN THE Globtype SHALL 不发起翻译，并在光标附近短暂提示"没有可翻译的内容"。
7. IF 源文本超过 5000 个字符，THEN THE Globtype SHALL 提示用户文本过长并不发起翻译。

### 需求 4：翻译与润色

**用户故事：** 作为中文母语用户，我希望我写的中文、中英混写或不地道的英文都能变成自然的英文。

#### 验收标准

1. WHEN 源文本主要为中文，THE Globtype SHALL 将其翻译为英文。
2. WHEN 源文本为中英混写，THE Globtype SHALL 按整句语义翻译为英文，并保留其中的英文专有名词和术语原样不变。
3. WHEN 源文本主要为英文，THE Globtype SHALL 进入润色模式，输出语法正确且表达自然的英文版本。
4. THE Globtype SHALL 在译文中保留源文本的段落结构，包括换行、空行和列表符号。
5. THE Globtype SHALL 在译文中原样保留源文本中的 URL、邮箱地址、@提及、#话题、emoji 和用反引号包裹的代码片段。
6. WHEN 翻译服务商支持流式输出，THE Globtype SHALL 在收到第一段译文后立即开始在悬浮面板中逐步显示译文。
7. THE Globtype SHALL 在与翻译相同的一次请求中获取 0 至 3 个具有学习价值的表达（详见需求 10）。
8. IF 翻译请求在 30 秒内未收到任何响应，THEN THE Globtype SHALL 中止请求并在悬浮面板中显示超时错误和重试选项。
9. IF 翻译服务商返回错误，THEN THE Globtype SHALL 在悬浮面板中以中文显示错误原因（如 Key 无效、余额不足、网络不可达）。

### 需求 5：悬浮面板

**用户故事：** 作为用户，我希望译文就出现在我打字的位置附近，并且全程用键盘就能完成操作。

#### 验收标准

1. WHEN 翻译被触发，THE Globtype SHALL 在目标输入框光标附近显示悬浮面板。
2. IF 无法获取光标的屏幕坐标，THEN THE Globtype SHALL 将悬浮面板显示在目标输入框下方；若也无法获取目标输入框位置，则显示在鼠标指针附近。
3. WHEN 悬浮面板的默认位置会超出屏幕可见区域，THE Globtype SHALL 调整面板位置使其完整可见。
4. WHILE 悬浮面板显示中，THE Globtype SHALL 保持目标 App 为前台 App，且不改变目标输入框的光标和选区。
5. WHILE 悬浮面板显示中且译文已完整生成，WHEN 用户按下 Enter 或点击译文，THE Globtype SHALL 执行回填（需求 6）并记录本次翻译（需求 9）。
6. WHILE 悬浮面板显示中且译文已完整生成，WHEN 用户按下 ⌥Enter，THE Globtype SHALL 执行回填但不记录本次翻译。
7. WHILE 悬浮面板显示中，WHEN 用户按下 R 或再次双击 Shift，THE Globtype SHALL 重新生成一个不同表述的译文。
8. WHILE 悬浮面板显示中且译文已完整生成，WHEN 用户按下 Tab，THE Globtype SHALL 展开中文讲解区域（需求 11）。
9. WHEN 用户按下 Esc 或点击悬浮面板以外的区域，THE Globtype SHALL 关闭悬浮面板，不修改目标输入框，不记录本次翻译。
10. WHILE 悬浮面板显示中，THE Globtype SHALL 拦截 Enter、⌥Enter、R、Tab、Esc 按键，使其不传递给目标 App。
11. WHILE 悬浮面板显示中，WHEN 用户按下 ⌘C，THE Globtype SHALL 将当前译文复制到剪贴板并关闭面板。
12. WHILE 译文正在生成中，THE Globtype SHALL 在悬浮面板中显示加载状态。

### 需求 6：回填译文

**用户故事：** 作为用户，我希望确认后译文直接替换我的原文，并且可以撤销。

#### 验收标准

1. WHEN 源文本来自选区，THE Globtype SHALL 用译文替换该选区。
2. WHEN 源文本来自全文，THE Globtype SHALL 用译文替换目标输入框的全部文本。
3. THE Globtype SHALL 优先通过辅助功能接口写入选区文本的方式回填，使目标 App 的撤销（⌘Z）可以恢复原文。
4. IF 通过辅助功能接口回填失败，THEN THE Globtype SHALL 通过剪贴板加模拟粘贴的方式回填，并在完成后将系统剪贴板恢复为回填前的内容。
5. WHEN 回填完成，THE Globtype SHALL 重新读取目标输入框内容以校验替换是否成功。
6. IF 校验发现回填未成功，THEN THE Globtype SHALL 将译文复制到剪贴板并提示"已复制到剪贴板，请手动粘贴"。
7. IF 在译文生成期间目标输入框的内容已被用户修改，THEN THE Globtype SHALL 在回填前提示用户原文已变化，并由用户选择仍然替换或取消。

### 需求 7：翻译服务商配置

**用户故事：** 作为用户，我希望使用自己的 API Key 或本地模型，并且没有 Key 时也能先试用。

#### 验收标准

1. THE Globtype SHALL 提供以下服务商预设：DeepSeek、通义千问、Kimi、智谱 GLM、硅基流动、OpenAI、Anthropic Claude、Google Gemini、Ollama、LM Studio、自定义 OpenAI 兼容地址。
2. THE Globtype SHALL 为每个预设自动填写默认接口地址和推荐模型名，并允许用户修改。
3. THE Globtype SHALL 将 API Key 存储在 macOS 钥匙串中，不以明文写入任何文件或日志。
4. WHEN 用户在设置中点击"测试连接"，THE Globtype SHALL 发送一次测试请求并显示成功或具体失败原因。
5. WHERE 用户未配置任何服务商，THE Globtype SHALL 使用 Apple 翻译框架提供翻译。
6. WHILE 使用 Apple 翻译框架，THE Globtype SHALL 不提供重新生成、中文讲解和表达提取功能，并在悬浮面板中提示"配置 API Key 可解锁更多功能"。
7. WHEN 使用 Apple 翻译框架所需的语言包未下载，THE Globtype SHALL 引导用户下载语言包。
8. THE Globtype SHALL 在设置中显示本月翻译次数和估算的 token 用量。

### 需求 8：权限与首次启动引导

**用户故事：** 作为用户，我希望首次打开时有清楚的步骤指导我放行和授权。

#### 验收标准

1. WHEN Globtype 首次启动，THE Globtype SHALL 显示引导窗口，依次引导用户授予辅助功能权限和输入监控权限。
2. WHILE 引导窗口显示中，THE Globtype SHALL 实时检测各项权限状态，并在权限授予后自动进入下一步。
3. IF 任一必需权限未授予，THEN THE Globtype SHALL 在菜单栏图标上显示警告标识，并在菜单中提供"修复权限"入口。
4. THE Globtype SHALL 在引导中让用户选择唤起方式：保留双击 Shift，或设置其他快捷键。
5. THE Globtype SHALL 在引导中让用户配置翻译服务商，并允许跳过（跳过后使用 Apple 翻译）。
6. THE Globtype SHALL 在引导中展示默认不记录的 App 建议列表（如银行、密码管理器），供用户勾选。
7. THE Globtype 的所有发布版本 SHALL 使用同一张自签名代码签名证书签名，使用户升级后已授予的权限保持有效。
8. THE Globtype 项目 SHALL 在 README 中说明首次打开时如何通过"系统设置 → 隐私与安全性 → 仍要打开"或 `xattr` 命令放行。

### 需求 9：表达库自动记录

**用户故事：** 作为用户，我希望我接受过的翻译都被自动保存，以后可以回查我是怎么表达的。

#### 验收标准

1. WHEN 用户通过 Enter 或点击接受译文，THE Globtype SHALL 在表达库中新增一条记录，包含源文本、译文、来源 App 名称和时间。
2. WHERE 来源 App 在用户的"不记录"列表中，THE Globtype SHALL 不记录该次翻译。
3. WHEN 写入表达库前，THE Globtype SHALL 将源文本和译文中的手机号、身份证号、邮箱地址和银行卡号替换为对应的占位符（如 `[手机号]`）。
4. WHEN 新记录的源文本与已有记录在归一化（去除首尾空白、统一标点全半角、合并连续空白）后相同，THE Globtype SHALL 合并为一条记录，更新译文和时间，并将使用次数加 1。
5. THE Globtype SHALL 提供表达库窗口，支持按关键词（中英文）、来源 App 和时间范围检索记录。
6. THE Globtype SHALL 允许用户删除单条记录、按时间范围删除记录或清空全部记录。
7. THE Globtype SHALL 将表达库仅存储在本机，不上传到任何服务器。

### 需求 10：表达提取与复习队列

**用户故事：** 作为用户，我希望从我的翻译里自动挑出值得学的表达，而不是每句话都让我复习。

#### 验收标准

1. WHEN 一次翻译被记录到表达库，THE Globtype SHALL 从本次翻译请求返回的表达中筛选出候选复习卡片。
2. THE Globtype SHALL 优先选择短语和搭配（如 `sync on`、`circle back`），而非单个常见单词。
3. WHEN 候选表达为单个单词且该单词在本地词典中标记为中考或高考词汇，THE Globtype SHALL 不将其加入复习队列。
4. WHEN 候选表达已存在于复习队列中，THE Globtype SHALL 不重复添加，并将该表达关联到本次记录。
5. WHEN 用户在复习中将某个表达标记为"太简单"，THE Globtype SHALL 将其从复习队列移除，并在以后的翻译中不再将其加入复习队列。
6. THE Globtype SHALL 限制每日新加入复习的卡片数量，默认上限为 10 张，用户可在设置中修改。
7. WHEN 当日新卡片数已达上限，THE Globtype SHALL 将多出的候选表达保存为待加入状态，并在之后的日子里按先后顺序补入。
8. WHEN 复习卡片是单个单词，THE Globtype SHALL 从本地词典获取其音标和中文释义，不调用翻译服务商。
9. WHEN 复习卡片是短语或搭配，THE Globtype SHALL 使用翻译请求中返回的中文释义。
10. THE Globtype SHALL 为每张复习卡片保存其出现时的原句（中文）和译句（英文）作为上下文。
11. WHEN 用户在表达库的任意记录中手动选择一段英文文本并添加到复习，THE Globtype SHALL 将其加入复习队列，不受每日上限限制。

### 需求 11：中文讲解

**用户故事：** 作为用户，我希望在需要时了解为什么这样翻译，特别是我的中式英语哪里不对。

#### 验收标准

1. WHEN 用户在悬浮面板中按下 Tab，THE Globtype SHALL 向翻译服务商请求本次翻译的中文讲解。
2. THE Globtype SHALL 仅在用户按下 Tab 后才发起讲解请求，不在翻译时预先请求。
3. THE Globtype SHALL 在讲解中给出 2 至 4 条要点，说明关键表达的选择理由。
4. WHEN 本次为润色模式，THE Globtype SHALL 在讲解中标出原文与译文的差异，并说明其中的中式英语表达。
5. WHEN 用户再次按下 Tab，THE Globtype SHALL 收起讲解区域。
6. WHEN 讲解已生成且本次翻译被记录，THE Globtype SHALL 将讲解一并保存到表达库记录中。

### 需求 12：复习

**用户故事：** 作为用户，我希望复习顺手发生，不用专门腾出时间。

#### 验收标准

1. THE Globtype SHALL 使用简化 SM-2 算法调度复习卡片：回答"记得"时间隔翻倍（首次为 1 天），间隔最长为 365 天；回答"忘了"时间隔重置为 0，卡片当天重新到期并排在当天到期队列的末尾，之后再回答"记得"时间隔从 1 天重新开始。
2. WHEN 悬浮面板显示且存在到期的复习卡片，THE Globtype SHALL 在面板底部以一行显示一张到期卡片的中文释义。
3. WHEN 用户点击面板底部的复习卡片，THE Globtype SHALL 展示对应英文表达和原句上下文，并提供"记得""忘了"两个选项。
4. THE Globtype SHALL 确保面板底部复习卡片的操作不影响悬浮面板的翻译操作按键（Enter、Esc 等）。
5. THE Globtype SHALL 在菜单栏菜单中显示当日到期的卡片数量。
6. WHEN 用户从菜单栏打开复习，THE Globtype SHALL 以闪卡形式逐张展示到期卡片：先显示中文释义与中文原句，用户翻面后显示英文表达、音标（如有）与英文译句。
7. THE Globtype SHALL 在闪卡中提供"记得""忘了""太简单"三个选项。
8. WHEN 某个表达在表达库中被使用 3 次或以上，THE Globtype SHALL 在悬浮面板中提示"这个表达你已经查过 N 次了"，并将其复习优先级提前。
9. THE Globtype SHALL 不在用户输入过程中主动弹出任何复习内容。
10. WHEN 用户在复习窗口中对某张卡片回答"忘了"，THE Globtype SHALL 将该卡片放回本轮复习的末尾再展示一次。

### 需求 13：菜单栏

**用户故事：** 作为用户，我希望从菜单栏快速访问 Globtype 的主要功能。

#### 验收标准

1. THE Globtype SHALL 以菜单栏图标形式常驻运行；WHILE 没有打开任何 Globtype 窗口，THE Globtype SHALL 不在程序坞中显示图标（有窗口时的行为见需求 15.4）。
2. THE Globtype SHALL 在菜单栏菜单中提供：启用/停用开关、打开学习中心、今日复习、打开表达库、设置、退出。
3. WHEN 用户在设置中开启"登录时启动"，THE Globtype SHALL 在用户登录 macOS 时自动启动。

### 需求 14：隐私

**用户故事：** 作为用户，我希望我的文本只发给我自己选的服务商，其余一律留在本机。

#### 验收标准

1. THE Globtype SHALL 仅将源文本发送给用户配置的翻译服务商（或本机的 Apple 翻译框架），不发送给其他任何网络地址。
2. THE Globtype SHALL 不包含任何使用统计、崩溃上报或遥测功能。
3. THE Globtype SHALL 不在应用日志中写入源文本、译文或 API Key。
4. THE Globtype SHALL 在发送给翻译服务商的请求中不附带来源 App 名称、窗口标题等上下文信息。

### 需求 15：学习中心窗口

**用户故事：** 作为用户，我希望有一个完整的学习界面，集中查看学习进度、做复习和管理表达，而不只是菜单栏里的几个小窗口。

#### 验收标准

1. THE Globtype SHALL 提供学习中心窗口，侧边栏包含：概览、复习、表达库、我的表达，底部提供打开设置的入口。
2. WHEN 用户在菜单栏选择"打开学习中心""今日复习"或"打开表达库"，THE Globtype SHALL 打开学习中心并切换到对应页面。
3. WHEN Globtype 已在运行且用户再次从访达、启动台或 Spotlight 打开它，THE Globtype SHALL 显示学习中心窗口。
4. WHILE Globtype 有任一窗口打开，THE Globtype SHALL 在程序坞和 ⌘Tab 切换器中显示图标；WHEN 所有窗口关闭，THE Globtype SHALL 从程序坞中隐藏。
5. WHEN 用户手动启动 Globtype 且已完成首次引导和授权，THE Globtype SHALL 显示学习中心；WHEN Globtype 作为登录项自动启动，THE Globtype SHALL 不显示任何窗口。
6. THE 侧边栏的"复习"项 SHALL 显示当日到期卡片数。
7. WHEN 学习数据发生变化（翻译被记录、复习、删除），THE 学习中心 SHALL 自动刷新显示内容。
8. THE Globtype SHALL 提供应用图标，在程序坞、访达和 ⌘Tab 中显示。

### 需求 16：学习概览

**用户故事：** 作为用户，我希望一眼看到自己学得怎么样，有继续用下去的动力。

#### 验收标准

1. THE 概览页 SHALL 显示：今日待复习数与"开始复习"按钮、连续学习天数、已掌握表达数、累计表达数。
2. THE Globtype SHALL 将连续学习天数计算为：截至今天（今天尚无活动时截至昨天）连续有翻译记录或复习的天数。
3. THE Globtype SHALL 将复习间隔达到 21 天及以上的表达计为"已掌握"。
4. THE 概览页 SHALL 以图表显示最近 14 天每天的翻译次数和复习次数。
5. THE 概览页 SHALL 显示使用次数最多的 5 个表达和最近 5 条翻译；WHEN 用户点击某条翻译，THE Globtype SHALL 跳转到表达库中的对应记录。
6. WHILE 表达库中没有任何记录，THE 概览页 SHALL 显示上手说明（唤起方式与面板快捷键）。
7. THE Globtype SHALL 按天累计翻译次数、复习次数与新增卡片数，统计数据不包含任何文本内容。

### 需求 17：我的表达

**用户故事：** 作为用户，我希望看到所有学过的表达及其掌握情况，并能调整哪些要复习。

#### 验收标准

1. THE 我的表达页 SHALL 列出所有提取过的表达，显示英文、中文释义、状态（复习中 / 排队中 / 已掌握 / 太简单）与使用次数。
2. THE 我的表达页 SHALL 支持按关键词（中英文）检索和按状态筛选。
3. WHEN 用户选中一个表达，THE Globtype SHALL 显示其音标（如有）、下次复习日期，以及它出现过的所有原句与译句。
4. WHEN 用户对"太简单"的表达选择"恢复复习"，THE Globtype SHALL 将其移出屏蔽列表并设为当天到期，不计入每日新卡上限。
5. WHEN 用户对复习中或排队中的表达选择"不再复习"，THE Globtype SHALL 按"太简单"处理（需求 10.5）。
