// SGLiveIslandWidget.swift — 灵动岛的「脸」
//
// 丝滑靠三件事：
//   1. 位移由 extension 自己的 TimelineView 每 0.2 秒本地重算，不走跨进程更新；
//   2. 位移 = 「已唱字数的小数位置」× 实测字宽，是亚像素连续移动，不是整字跳格；
//   3. 字宽用 monospaced 字体实测一次并缓存（只有 4 个可能值），既准又不产生分配。
//
// 数据全部来自 ContentState：主 App 只在换行时推一次。

import ActivityKit
import Foundation
import SwiftUI
import UIKit
import WidgetKit

// MARK: - 字宽（等宽字体，实测一次后常量级缓存）

private enum Metrics {
    // 只会出现 (2 种字符 × 3 档字号) = 6 项，绝不增长
    private static var cache: [String: CGFloat] = [:]

    static func font(_ size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    }

    static func width(ascii: Bool, size: CGFloat) -> CGFloat {
        let key = ascii ? "a\(Int(size))" : "c\(Int(size))"
        if let v = cache[key] { return v }
        let probe = ascii ? "a" : "中"
        let w = (probe as NSString).size(withAttributes: [.font: font(size)]).width
        cache[key] = w
        return w
    }

    static func width(_ c: Character, size: CGFloat) -> CGFloat {
        width(ascii: c.isASCII, size: size)
    }

    /// 前 p 个字（p 可带小数）的累计宽度
    static func offset(_ chars: [Character], upTo p: Double, size: CGFloat) -> CGFloat {
        guard !chars.isEmpty else { return 0 }
        let whole = min(max(Int(p), 0), chars.count)
        var w: CGFloat = 0
        for i in 0..<whole { w += width(chars[i], size: size) }
        if whole < chars.count {
            w += width(chars[whole], size: size) * CGFloat(p - Double(whole))
        }
        return w
    }
}

// MARK: - 进度

private enum Scroll {
    /// 已唱字数的小数位置：整数部分是唱完的字，小数部分是当前字唱到的比例。
    static func position(_ s: SGLyricsAttributes.ContentState, at date: Date) -> Double {
        let total = s.line.count
        guard total > 0 else { return 0 }
        let ref = s.paused ? (s.pausedAt ?? s.lineStart) : date
        let elapsed = ref.timeIntervalSince(s.lineStart)
        guard elapsed > 0 else { return 0 }

        if !s.wordTimes.isEmpty {
            var prev = 0.0
            for (i, t) in s.wordTimes.enumerated() {
                if t <= elapsed { prev = t; continue }
                let span = max(t - prev, 0.001)
                let frac = min(max((elapsed - prev) / span, 0), 1)
                return min(Double(i) + frac, Double(total))
            }
            return Double(total)
        }

        guard s.lineDuration > 0 else { return 0 }
        return min(max(elapsed / s.lineDuration, 0), 1) * Double(total)
    }
}

// MARK: - 样式

private func fontSize(_ s: SGLyricsAttributes.ContentState, compact: Bool) -> CGFloat {
    switch s.fontStep {
    case 0: return compact ? 11 : 20
    case 2: return compact ? 15 : 26
    default: return compact ? 13 : 23
    }
}

private func accentColor(_ s: SGLyricsAttributes.ContentState) -> Color {
    Color(hex: s.accent)
}

private func lyricColor(_ s: SGLyricsAttributes.ContentState) -> Color {
    s.useArtworkColor ? Color(hex: s.accent) : .white
}

// MARK: - 入口

@available(iOS 17.0, *)
@main
struct SGLiveIslandBundle: WidgetBundle {
    var body: some Widget {
        SGLyricsLiveActivity()
    }
}

@available(iOS 17.0, *)
struct SGLyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SGLyricsAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(.black.opacity(0.45))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    ExpandedLyrics(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedFooter(state: context.state)
                }
            } compactLeading: {
                CompactLyrics(state: context.state)
            } compactTrailing: {
                CompactTail(state: context.state)
            } minimal: {
                MinimalGlyph(state: context.state)
            }
            .keylineTint(accentColor(context.state))
        }
    }
}

// MARK: - compact：单行滚动，不高亮

@available(iOS 17.0, *)
private struct CompactLyrics: View {
    let state: SGLyricsAttributes.ContentState

    var body: some View {
        let size = fontSize(state, compact: true)
        let chars = Array(state.line)

        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let p = Scroll.position(state, at: ctx.date)
            let shift = Metrics.offset(chars, upTo: p, size: size)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Text(displayText)
                        .font(.system(size: size, weight: .semibold, design: .monospaced))
                        .foregroundStyle(lyricColor(state))
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: -shift)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.06),
                            .init(color: .black, location: 0.84),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            }
            .frame(width: compactWidth(state), height: size + 6)
        }
    }

    private var displayText: String {
        if !state.line.isEmpty { return state.line }
        return state.paused ? "已暂停" : "♪"
    }

    /// 系统给 compact 区的宽度是固定的（约 60pt），这里只用设置项在
    /// 「标准」和「最长」之间做两档，避免把布局撑出界。
    private func compactWidth(_ s: SGLyricsAttributes.ContentState) -> CGFloat {
        s.windowChars >= 10 ? 74 : 58
    }
}

// MARK: - compact 右侧

@available(iOS 17.0, *)
private struct CompactTail: View {
    let state: SGLyricsAttributes.ContentState

    var body: some View {
        Image(systemName: state.paused ? "pause.fill" : "waveform")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(lyricColor(state).opacity(0.9))
            .frame(width: 16)
    }
}

// MARK: - minimal

@available(iOS 17.0, *)
private struct MinimalGlyph: View {
    let state: SGLyricsAttributes.ContentState

    var body: some View {
        Image(systemName: state.paused ? "pause.fill" : "music.note")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(lyricColor(state))
    }
}

// MARK: - expanded：整行 + 逐字高亮

@available(iOS 17.0, *)
private struct ExpandedLyrics: View {
    let state: SGLyricsAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            Text(highlighted(state.sungCount(at: ctx.date)))
                .font(.system(size: fontSize(state, compact: false),
                              weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
        }
    }

    private func highlighted(_ sung: Int) -> AttributedString {
        var a = AttributedString(state.line.isEmpty ? "♪" : state.line)
        let total = a.characters.count
        let idx = a.index(a.startIndex, offsetBy: min(max(sung, 0), total))
        a[a.startIndex..<idx].foregroundColor = lyricColor(state)
        a[idx...].foregroundColor = Color.white.opacity(0.42)
        return a
    }
}

// MARK: - expanded 底部：下一行

@available(iOS 17.0, *)
private struct ExpandedFooter: View {
    let state: SGLyricsAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            Text(state.nextLine.isEmpty ? " " : state.nextLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if state.paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 锁屏

@available(iOS 17.0, *)
private struct LockScreenView: View {
    let state: SGLyricsAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                Text(highlighted(state.sungCount(at: ctx.date)))
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                if !state.nextLine.isEmpty {
                    Text(state.nextLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func highlighted(_ sung: Int) -> AttributedString {
        var a = AttributedString(state.line.isEmpty ? "♪" : state.line)
        let total = a.characters.count
        let idx = a.index(a.startIndex, offsetBy: min(max(sung, 0), total))
        a[a.startIndex..<idx].foregroundColor = lyricColor(state)
        a[idx...].foregroundColor = Color.white.opacity(0.42)
        return a
    }
}

// MARK: - 颜色

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self.init(red: 0.12, green: 0.84, blue: 0.38)
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
