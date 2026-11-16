// SGLiveIslandWidget.swift
// 参照灵动歌词的实际显示：灵动岛单行裁切滚动；锁屏与展开态「下一行 + 当前行 + 译文」。
// 滚动由系统时钟效果驱动（ClockDriver），失败时静态一行，不做假动画。

import ActivityKit
import Foundation
import SwiftUI
import UIKit
import WidgetKit

private enum LyricMetrics {
    static func fontSize(_ step: Int, big: Bool) -> CGFloat {
        switch step {
        case 0: return big ? 17 : 12
        case 2: return big ? 23 : 15
        default: return big ? 20 : 13
        }
    }

    static func uiFont(_ step: Int, big: Bool) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: fontSize(step, big: big), weight: .semibold)
    }

    static func font(_ step: Int, big: Bool) -> Font {
        .system(size: fontSize(step, big: big), weight: .semibold, design: .monospaced)
    }

    static func width(_ text: String, step: Int, big: Bool) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: uiFont(step, big: big)]).width
    }
}

private func lyricColor(_ s: SGLyricsAttributes.ContentState) -> Color {
    s.useArtworkColor ? Color(hex: s.accent) : .white
}

@available(iOS 16.1, *)
@main
struct SGLiveIslandBundle: WidgetBundle {
    var body: some Widget { SGLyricsLiveActivity() }
}

@available(iOS 16.1, *)
struct SGLyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SGLyricsAttributes.self) { context in
            LockScreenLyrics(state: context.state)
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "spotify://"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    ExpandedLyrics(state: context.state)
                }
            } compactLeading: {
                IslandLine(state: context.state)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : "music.note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(lyricColor(context.state))
            }
            .keylineTint(Color(hex: context.state.accent))
            .widgetURL(URL(string: "spotify://"))
        }
    }
}

// MARK: - 灵动岛：单行，超宽时按节奏左移

@available(iOS 16.1, *)
private struct IslandLine: View {
    let state: SGLyricsAttributes.ContentState
    private let period = 3600.0
    private let viewport: CGFloat = 62

    var body: some View {
        let step = state.fontStep
        let text = visibleText
        let lineHeight = LyricMetrics.uiFont(step, big: false).lineHeight
        let width = LyricMetrics.width(text, step: step, big: false)
        let radius = radiusFor(width: width)
        let label = Text(text)
            .font(LyricMetrics.font(step, big: false))
            .foregroundStyle(lyricColor(state))
            .lineLimit(1)
            .fixedSize()

        return Group {
            if radius > 0, !state.paused, ClockDriver<Text, Text>.isAvailable {
                ClockDriver(
                    moving: label
                        .frame(width: 2 * radius, height: 2 * radius, alignment: .top)
                        .rotationEffect(.radians(phase), anchor: .center),
                    fallback: staticLine(label, lineHeight: lineHeight),
                    verticalReturn: radius - lineHeight * 0.5
                )
            } else {
                staticLine(label, lineHeight: lineHeight)
            }
        }
        .frame(width: viewport, height: lineHeight, alignment: .leading)
        .clipped()
    }

    private func staticLine(_ label: Text, lineHeight: CGFloat) -> some View {
        label.frame(width: viewport, height: lineHeight, alignment: .leading)
    }

    private var visibleText: String {
        if !state.line.isEmpty { return String(state.line.prefix(200)) }
        return state.paused ? "已暂停" : "♪"
    }

    private var phase: Double {
        let epoch = state.lineStart.timeIntervalSince1970
        let base = 2 * Double.pi * epoch.truncatingRemainder(dividingBy: period) / period
        guard state.lineDuration > 0, !state.paused else { return base }
        let fraction = min(1, max(0, Date().timeIntervalSince(state.lineStart) / state.lineDuration))
        return base + 2 * Double.pi * fraction
    }

    private func radiusFor(width: CGFloat) -> CGFloat {
        guard state.smoothScroll, state.lineDuration.isFinite,
              (0.3...60).contains(state.lineDuration), width > viewport else { return 0 }
        let distance = width + 20 - viewport
        let radius = distance * CGFloat(period / (2 * Double.pi * state.lineDuration))
        // 半径过大退回静态一行；夹紧会改变语速，所以不夹。
        guard radius.isFinite, radius >= 1, radius <= 4096 else { return 0 }
        return radius
    }
}

// MARK: - 锁屏：下一行 + 当前行 + 译文（对齐灵动歌词）

@available(iOS 16.1, *)
private struct LockScreenLyrics: View {
    let state: SGLyricsAttributes.ContentState

    var body: some View {
        VStack(spacing: 3) {
            if !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
            Text(mainLine)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(lyricColor(state))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if !state.translation.isEmpty {
                Text(state.translation)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var mainLine: String {
        if !state.line.isEmpty { return String(state.line.prefix(200)) }
        return state.paused ? "已暂停" : "♪"
    }
}

// MARK: - 展开态

@available(iOS 16.1, *)
private struct ExpandedLyrics: View {
    let state: SGLyricsAttributes.ContentState

    var body: some View {
        VStack(spacing: 4) {
            Text(mainLine)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(lyricColor(state))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !state.translation.isEmpty {
                Text(state.translation)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            if !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var mainLine: String {
        if !state.line.isEmpty { return String(state.line.prefix(200)) }
        return state.paused ? "已暂停" : "♪"
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789ABCDEFabcdef"))
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self.init(red: 0.12, green: 0.84, blue: 0.38)
            return
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
