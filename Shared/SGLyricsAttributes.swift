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
        /// 下一行，expanded / 锁屏用；没有就空串。
        var nextLine: String
        var title: String
        var artist: String
        var paused: Bool

        /// 这一行开始的绝对时刻。extension 用 now - lineStart 得到已唱秒数。
        /// 主 App 用「播放位置 - 行起始毫秒」反推，所以换行检测的延迟不影响滚动精度。
        var lineStart: Date

        /// 每个字相对 lineStart 的起唱秒数，长度与 line.count 一致。
        /// 快歌间隔小、慢歌间隔大，推进速度天然跟随歌词本身。
        var wordTimes: [Double]

        /// 这一行总时长（秒）。wordTimes 为空时按它均分。
        var lineDuration: Double

        /// 暂停时刻：冻结显示位置，并给 staleDate 计时。
        var pausedAt: Date?

        // ── 设置（由 App 侧读取后下发）──
        /// 0 小 / 1 标准 / 2 大
        var fontStep: Int
        /// compact 滑动窗口显示的字数（标准 8，最长 12）
        var windowChars: Int
        /// 是否用封面主色（真时 accent 有效）
        var useArtworkColor: Bool
        /// TimelineView 的刷新周期（秒），由主 App 按「平滑」档位下发。
        /// 对应灵动歌词的 refreshTime：它也是运行时算好再传给 extension 的。
        var refreshTime: Double
        /// 平滑滚动开关（对应它的 _smoothDI）。关掉时整行原地不滚。
        var smoothScroll: Bool
        /// 主题色，6 位 hex 不带 #
        var accent: String

        static let defaultAccent = "1ED760"
    static let defaultRefresh: Double = 0.2

        /// 到 now 为止已唱完的字数（0…line.count）。
        /// 纯函数，不保存状态，extension 每秒调一次即可。
        func sungCount(at now: Date) -> Int {
            let total = line.count
            guard total > 0 else { return 0 }
            let ref = paused ? (pausedAt ?? lineStart) : now
            let elapsed = ref.timeIntervalSince(lineStart)
            guard elapsed > 0 else { return 0 }

            if !wordTimes.isEmpty {
                // wordTimes 已按升序排好，线性扫描即可（一行最多几十个元素）
                var n = 0
                for t in wordTimes where t <= elapsed { n += 1 }
                return min(n, total)
            }
            guard lineDuration > 0 else { return 0 }
            let ratio = min(max(elapsed / lineDuration, 0), 1)
            return Int(Double(total) * ratio)
        }
    }
}
