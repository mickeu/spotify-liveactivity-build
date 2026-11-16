// Runtime construction technique informed by giljihun/ClockHandKit (MIT).
// Copyright (c) 2026 GIL
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to do
// so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import OSLog
import SwiftUI
import WidgetKit

/// Private-runtime experiment, not a public WidgetKit animation guarantee.
/// Static fallback is a separate, SMALL view: never return the unrotated circle.
@available(iOS 16.1, *)
@MainActor
struct ClockDriver<Moving: View, Fallback: View>: View {
    let moving: Moving
    let fallback: Fallback
    let verticalReturn: CGFloat

    var body: some View {
        if let modifier = ClockRuntime.modifier {
            // `any ViewModifier` 不能直接当作 View，且需要存在体打开成具体 M。
            // 转成 AnyView 后分支两侧类型一致，桥接失败时不进入这里的巨型布局。
            AnyView(opened(moving, modifier: modifier).offset(y: verticalReturn))
        } else {
            AnyView(fallback)
        }
    }

    private func opened<V: View, M: ViewModifier>(_ view: V, modifier: M) -> some View {
        view.modifier(modifier)
    }

    static var isAvailable: Bool { ClockRuntime.modifier != nil }
}

@available(iOS 16.1, *)
@MainActor
private enum ClockRuntime {
    private static let log = Logger(subsystem: "SGLiveIsland", category: "clock-driver")

    private struct Payload: Encodable {
        private enum Keys: String, CodingKey {
            case period, timeZone, anchor, honorIdealizedDate
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(-3600.0, forKey: .period)
            // Fixed UTC removes DST/time-zone changes from the phase experiment.
            try c.encode(TimeZone(secondsFromGMT: 0) ?? TimeZone.current, forKey: .timeZone)
            try c.encode(false, forKey: .honorIdealizedDate)
            var a = c.nestedUnkeyedContainer(forKey: .anchor)
            try a.encode(0.5)
            try a.encode(0.5)
        }
    }

    // Main-actor isolated static initialization: one attempt, one JSON payload,
    // one decode and at most one diagnostic per extension process, NOT per frame.
    static let modifier: (any ViewModifier)? = {
        guard let type = _typeByName("9WidgetKit24_ClockHandRotationEffectV"),
              let decodable = type as? any Decodable.Type else {
            log.error("Clock driver unavailable: private type/Decodable missing; static lyric")
            return nil
        }
        do {
            let data = try JSONEncoder().encode(Payload())
            let decoded = try JSONDecoder().decode(decodable, from: data)
            guard let modifier = decoded as? any ViewModifier else {
                log.error("Clock driver unavailable: ViewModifier conformance missing; static lyric")
                return nil
            }
            return modifier
        } catch {
            log.error("Clock driver decode failed; static lyric: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()
}
