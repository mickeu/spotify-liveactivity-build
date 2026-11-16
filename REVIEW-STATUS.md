# LiveIsland — 开发中，未通过验收

禁止当作已验证插件交付/签装；未完成实机验证。

## 代码已落地
- 主 App 侧 `Source/SGLLiveIsland.swift`：读插件 `SGKaraoke*` 歌词引擎，按播放器位置重锚时间轴，单消费者队列更新/关闭，generation 取消旧状态，失败退避。
- 渲染 `Widget/SGLiveIslandWidget.swift` + `Widget/ClockDriver.swift`：按反汇编核证的做法，用系统时钟效果做大半径旋转、近似单行水平滚动；失败时静态单行降级。不使用 TimelineView 轮询当主驱动。
- 设置页 `Source/Settings.m`：链式替换 `-[SGModPage initWithTitle:intro:sections:footer:]`，仅匹配原歌词页（锁屏歌词 row key），初始化参数里追加 section。
- 封面取色 `Source/Artwork.m`：`SGRNowPlayingArtwork` 只读缓存 + 曲目 URI 校验，32×32 RGBA 单张采样，无网络请求。
- 解析与发送有硬上限：≤4096 行、每行 ≤128 字符/768 字节、≤256 词、payload ≤3584 字节。
- KVC 全部走 ObjC `@try/@catch`；类状态 `@MainActor`；观察者保存 token。

## 已验证（仅本地）
- `swiftc -frontend -parse`：dylib 目标与 widget 目标均通过（语法级）。
- `clang -fsyntax-only` + iPhoneOS 26.5 SDK：Bootstrap/Settings/Artwork 均通过，无警告。
- `Tests/main.swift`：14 项边界 + 10,001 个时间采样 PASS。
- **未做**：Apple SDK 类型检查全量、链接、签名、注入、真机后台/内存/流畅度测试。

## 施工中/待验证
- ClockEffect 大半径弧的相位对齐（`lineStart` 与系统时钟相位）只在数学上自洽，需真机看观感。
- 封面取色依赖原插件 Redesigned UI 的缓存；未启用时退默认色（不冒充）。
- 设置页是否与 Redesigned/原生两种外观都命中，需真机确认。
- 后台 Timer 停摆属平台约束：后台换行可能滞后，需真机实测。
- `staleDate` 只标过期，不保证自动移除。

## 交付前
重新做三轮完整审查 + SDK 类型检查 + 链接 + 签名 + 真机测试，再生成 IPA。