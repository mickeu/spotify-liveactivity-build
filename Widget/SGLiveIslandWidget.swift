// SGLiveIslandWidget.swift
// 对齐灵动歌词的显示逻辑：
//   · 灵动岛：单行，两侧渐隐，超出宽度按歌词时长匀速左移（系统时钟效果驱动）
//   · 锁屏 / 展开：上一行 + 当前行 + 译文 + 下一行 + 下一行译文
// 桥接失败一律退回静态单行，不做假动画。

import ActivityKit
import Foundation
import SwiftUI
import UIKit
import WidgetKit

private enum Metrics {
    /// 灵动岛单行字号（小 / 标准 / 大）
    static func islandSize(_ step: Int) -> CGFloat {
        switch step {
        case 0: return 12
        case 2: return 15
        default: return 13
        }
    }

    /// 锁屏与展开态的字号层级
    static func bodySize(_ step: Int, big: Bool) -> CGFloat {
        let base: CGFloat
        switch step {
        case 0: base = 17
        case 2: base = 21
        default: base = 19
        }
        return big ? base + 1 : base
    }

    static func width(_ text: String, size: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: .semibold)]).width
    }
}

private func lyricColor(_ s: SGLyricsAttributes.ContentState) -> Color {
    s.useArtworkColor ? Color(hex: s.accent) : .white
}

/// 两侧渐隐，灵动歌词的 leftFade / rightFade
private struct EdgeFade: ViewModifier {
    var width: CGFloat = 10
    func body(content: Content) -> some View {
        content.mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: width / 62.0),
                    .init(color: .black, location: 1 - width / 62.0),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }
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
                .activityBackgroundTint(.black.opacity(0.5))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "spotify://"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    LockScreenLyrics(state: context.state, expanded: true)
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

// MARK: - 灵动岛单行

@available(iOS 16.1, *)
private struct IslandLine: View {
    let state: SGLyricsAttributes.ContentState
    private let period = 3600.0
    private let viewport: CGFloat = 60

    var body: some View {
        let size = Metrics.islandSize(state.fontStep)
        let lineHeight = UIFont.systemFont(ofSize: size, weight: .semibold).lineHeight
        let text = visibleText
        let textWidth = Metrics.width(text, size: size)
        let radius = radiusFor(width: textWidth)
        let label = Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(lyricColor(state))
            .lineLimit(1)
            .fixedSize()

        return Group {
            if radius > 0, !state.paused, ClockDriver<Text, Text>.isAvailable {
                ClockDriver(
                    moving: label
                        .frame(width: 2 * radius, height: 2 * radius, alignment: .top)
                        .rotationEffect(.radians(phase), anchor: .center),
                    fallback: fixed(label, lineHeight),
                    verticalReturn: radius - lineHeight * 0.5
                )
            } else {
                fixed(label, lineHeight)
            }
        }
        .frame(width: viewport, height: lineHeight, alignment: .leading)
        .modifier(EdgeFade())
        .clipped()
    }

    private func fixed(_ label: Text, _ lineHeight: CGFloat) -> some View {
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
              (0.3...60).contains(state.lineDuration), width > viewport + 20 else { return 0 }
        let distance = width + 20 - viewport
        let radius = distance * CGFloat(period / (2 * Double.pi * state.lineDuration))
        guard radius.isFinite, radius >= 1, radius <= 4096 else { return 0 }
        return radius
    }
}

// MARK: - 锁屏 / 展开：上下文 + 译文

@available(iOS 16.1, *)
private struct LockScreenLyrics: View {
    let state: SGLyricsAttributes.ContentState
    var expanded = false

    var body: some View {
        let size = Metrics.bodySize(state.fontStep, big: expanded)
        VStack(spacing: expanded ? 4 : 3) {
            if !state.prevLine.isEmpty {
                Text(state.prevLine)
                    .font(.system(size: size - 4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
            }
            Text(mainLine)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(lyricColor(state))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if !state.translation.isEmpty {
                Text(state.translation)
                    .font(.system(size: size - 3, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            if !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(.system(size: size - 4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
            }
            if !state.nextTranslation.isEmpty {
                Text(state.nextTranslation)
                    .font(.system(size: size - 5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, expanded ? 6 : 8)
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
