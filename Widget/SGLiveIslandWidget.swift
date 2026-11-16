// SGLiveIslandWidget.swift
// 单行灵动歌词：ClockEffect 驱动连续运动，失败时静态降级。
// 不使用 TimelineView 作为滚动主驱动；不显示逐字高亮、下一行或控制栏。

import ActivityKit
import Foundation
import SwiftUI
import UIKit
import WidgetKit

private enum LyricMetrics {
    static func font(_ step: Int, compact: Bool) -> UIFont {
        let size: CGFloat
        switch step {
        case 0: size = compact ? 11 : 20
        case 2: size = compact ? 15 : 26
        default: size = compact ? 13 : 23
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    }

    static func swiftUIFont(_ step: Int, compact: Bool) -> Font {
        let u = font(step, compact: compact)
        return .system(size: u.pointSize, weight: .semibold, design: .monospaced)
    }

    static func width(_ text: String, font: UIFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

private func safe(_ value: Double, fallback: Double = 0) -> Double {
    value.isFinite ? value : fallback
}

private func safe(_ value: CGFloat, fallback: CGFloat = 0) -> CGFloat {
    value.isFinite ? value : fallback
}

private func lyricColor(_ state: SGLyricsAttributes.ContentState) -> Color {
    state.useArtworkColor ? Color(hex: state.accent) : .white
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
            ClockLyricLine(state: context.state, compact: false)
                .activityBackgroundTint(.black.opacity(0.45))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    ClockLyricLine(state: context.state, compact: false)
                }
            } compactLeading: {
                ClockLyricLine(state: context.state, compact: true)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(lyricColor(context.state))
            }
            .keylineTint(Color(hex: context.state.accent))
        }
    }
}

@available(iOS 16.1, *)
@MainActor
private struct ClockLyricLine: View {
    let state: SGLyricsAttributes.ContentState
    let compact: Bool
    var minimal = false
    private let period = 3600.0

    var body: some View {
        if !state.islandHidden {
            GeometryReader { geo in
                let viewport = min(max(safe(geo.size.width), 1), requestedWidth)
                let uiFont = LyricMetrics.font(state.fontStep, compact: compact)
                // Untrusted content must not create unbounded text/layout storage.
                let debug = state.line.isEmpty ? state.artist : ""
                let text = state.line.isEmpty
                    ? (debug.isEmpty ? "♪" : debug)
                    : String(state.line.prefix(512)).replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                let width = safe(LyricMetrics.width(text, font: uiFont))
                let radius = radiusFor(width: width, viewport: viewport)
                let elapsed = frozenElapsed()
                let phase = 2 * Double.pi * phaseSeconds() / period
                    + Double.pi * safe(state.lineDuration) / period
                let label = Text(text)
                    .font(LyricMetrics.swiftUIFont(state.fontStep, compact: compact))
                    .foregroundStyle(lyricColor(state))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                // Small leading-aligned fallback, never a cropped giant circle.
                let fallback = label.frame(width: viewport, height: uiFont.lineHeight, alignment: .leading)

                Group {
                    if radius > 0 && state.paused {
                        // Stop the private driver entirely. Freeze the SAME arc
                        // geometry at pausedAt; resume receives a rebased lineStart.
                        if ClockDriver<Text, Text>.isAvailable {
                            label
                                .frame(width: 2 * radius, height: 2 * radius, alignment: .top)
                                .rotationEffect(.radians(
                                    Double.pi * state.lineDuration / period - 2 * Double.pi * elapsed / period
                                ), anchor: .center)
                                .offset(y: radius - uiFont.lineHeight * 0.5)
                        } else {
                            fallback
                        }
                    } else if radius > 0 {
                        ClockDriver(
                            moving: label
                                .frame(width: 2 * radius, height: 2 * radius, alignment: .top)
                                .rotationEffect(.radians(phase), anchor: .center),
                            fallback: fallback,
                            verticalReturn: radius - uiFont.lineHeight * 0.5
                        )
                    } else {
                        fallback
                    }
                }
                .frame(width: viewport, height: uiFont.lineHeight + 4, alignment: .center)
                .clipped()
            }
            .frame(width: compact ? requestedWidth : nil, height: lineHeight)
            .frame(maxWidth: compact ? nil : requestedWidth)
            .clipped()
        }
    }

    private var requestedWidth: CGFloat {
        if minimal { return 26 }
        if compact { return state.windowChars >= 10 ? 74 : 58 }
        return state.windowChars >= 10 ? 300 : 240
    }

    private var lineHeight: CGFloat {
        LyricMetrics.font(state.fontStep, compact: compact).lineHeight + 4
    }

    private func radiusFor(width: CGFloat, viewport: CGFloat) -> CGFloat {
        guard state.smoothScroll, width > viewport,
              state.lineDuration.isFinite, (0.25...120).contains(state.lineDuration),
              state.lineStart.timeIntervalSince1970.isFinite,
              !state.paused || (state.pausedAt?.timeIntervalSince1970.isFinite == true)
        else { return 0 }
        let raw = (width + 20 - viewport) * CGFloat(period / (2 * Double.pi * state.lineDuration))
        // Reject, NEVER clamp: clamping R would silently change the singing speed.
        // No drawingGroup/blur/shadow/mask or bitmap of this circle is requested.
        // A frame is layout, not an allocation guarantee; device memory profiling
        // is still mandatory. Oversized radius means static text, honestly.
        guard raw.isFinite, raw >= 1, raw <= 4096 else { return 0 }
        let now = Date().timeIntervalSince(state.lineStart)
        guard now.isFinite, state.paused || (now >= 0 && now <= state.lineDuration) else { return 0 }
        return raw
    }

    private func frozenElapsed() -> Double {
        guard state.paused, let at = state.pausedAt else { return 0 }
        let elapsed = safe(at.timeIntervalSince(state.lineStart))
        return min(max(elapsed, 0), max(safe(state.lineDuration), 0))
    }

    private func phaseSeconds() -> Double {
        let t = safe(state.lineStart.timeIntervalSince1970)
        let m = t.truncatingRemainder(dividingBy: period)
        return m < 0 ? m + period : m
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
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
