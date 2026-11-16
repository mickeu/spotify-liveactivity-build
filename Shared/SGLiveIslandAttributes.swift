// SGLiveIslandAttributes.swift
// 主 App 侧 dylib 与 widget extension 共用。
// ActivityKit 按类型名（含模块名）配对两边，所以本文件必须两边同源编译，
// 模块名统一为 SGLiveIsland（CFBundleIdentifier 不受影响）。
//
// 数据全部来自 spotifyglass 的歌词引擎（SGKaraoke* C 符号），插件本身零改动。

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct SGLyricsAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        /// 当前正在唱的行（纯文本，未分字）。compact 的滑动窗口就用它切。
        var line: String
        /// 下一行，expanded/锁屏用；没有就空串。
        var nextLine: String
        /// 曲目与歌手（暂未使用，留给后续扩展）。
        var title: String
        var artist: String
        /// 暂停时不推进时间轴。
        var paused: Bool

        /// 这一行开始唱的绝对时刻（Date）。extension 用它和 now 求差得到进度。
        var lineStart: Date
        /// 每个字相对行首的起唱时间（秒），长度 = line.count。
        /// 来源 SGKaraokeWord.start/end，已按 leadLine 取出。
        var wordTimes: [Double]
        /// 这一行的总时长（秒），wordTimes 为空时用它均分。
        var lineDuration: Double

        /// 主题色，6 位 hex（不带 #），来自封面取色；拿不到时用默认绿。
        var accent: String
        /// 整首曲目进度 0…1，锁屏进度条用。
        var progress: Double

        static let fallbackAccent = "1ED760"

        /// 给定时刻的逐字进度：返回"已唱完的字数"（0…line.count）。
        /// extension 每秒调一次，1 Hz 足够，不触发节流。
        func sungCount(at now: Date) -> Int {
            let chars = Array(line)
            guard !chars.isEmpty else { return 0 }
            if paused { return lastSungCount }         // 暂停时冻结（由主 App 写入）
            let t = now.timeIntervalSince(lineStart)
            if t <= 0 { return 0 }
            if !wordTimes.isEmpty {
                let idx = wordTimes.lastIndex { $0 <= t }
                return idx.map { min($0 + 1, chars.count) } ?? 0
            }
            // 没有逐字时间：按行时长均分估算
            guard lineDuration > 0 else { return 0 }
            let ratio = min(max(t / lineDuration, 0), 1)
            return Int(Double(chars.count) * ratio)
        }

        /// 暂停冻结用：主 App 在 pause 时把当时的字数写进来。
        /// 不参与 Codable 语义之外的逻辑，仅作缓存；缺省 0 也无碍。
        var lastSungCount: Int = 0

        enum CodingKeys: String, CodingKey {
            case line, nextLine, title, artist, paused
            case lineStart, wordTimes, lineDuration, accent, progress, lastSungCount
        }
    }
}
