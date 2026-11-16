// SGLyricsAttributes.swift
//
// 主 App 侧 dylib 与 widget extension 共用这一份。
// ActivityKit 按类型的 mangled 名（含模块名）把两边配对，所以：
//   - 本文件必须在两个 target 里同源编译
//   - 两个 target 的模块名都必须是 SGLiveIsland
//   - 字段改一处，两边必须同时改
//
// extension 是独立进程，读不到 App 的 UserDefaults，所以字号/宽度/配色
// 这些设置项必须随 ContentState 一起传下来。

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct SGLyricsAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        /// 当前行纯文本（已按字的真实间隔展开，空格也算一个位置）。
        var line: String
        /// 上一行 / 下一行（锁屏与展开态的上下文，灵动歌词同款布局）。
        var prevLine: String
        var nextLine: String
        /// 当前行的译文；下一行的译文。
        var translation: String
        var nextTranslation: String
        var paused: Bool

        /// 这一行开始的绝对时刻。主 App 用播放器位置反推，换行检测延迟不影响滚动精度。
        var lineStart: Date

        /// 这一行总时长（秒）。滚动速度与进度都按它算。
        var lineDuration: Double

        /// 暂停时刻：冻结显示位置，并给 staleDate 计时。
        var pausedAt: Date?

        // ── 设置（由 App 侧读取后下发）──
        /// 0 小 / 1 标准 / 2 大
        var fontStep: Int
        /// 是否用封面主色（真时 accent 有效）
        var useArtworkColor: Bool
        /// 隐藏岛上内容，但保持实时活动与锁屏内容存在。
        var islandHidden: Bool
        /// 灵动岛宽度：false 标准 / true 最长（对应设置项「宽度」）
        var wideIsland: Bool
        /// 平滑滚动开关（对应它的 _smoothDI）。关掉时整行原地不滚。
        var smoothScroll: Bool
        /// 锁屏/展开是否显示译文（对应「显示翻译」）
        var showTranslation: Bool
        /// 主题色，6 位 hex 不带 #
        var accent: String

        static let defaultAccent = "1ED760"

    }
}
