// ClockDriver.swift
// 运行时桥接 WidgetKit 的私有时钟效果 _ClockHandRotationEffect。
// 构造方式参考 giljihun/ClockHandKit（MIT）。
//
// 关键几何：周期 = 这一行的时长。于是
//   R = 位移长度 / 2π
//   ω = 2π / duration   →   线速度 = R·ω = 位移长度 / duration
// 也就是「唱完这一行，文字正好走完自己的宽度」，天然跟随歌词快慢。

import Foundation
import OSLog
import SwiftUI
import UIKit
import WidgetKit

@available(iOS 16.1, *)
struct ClockDriver<Moving: View, Fallback: View>: View {
    let moving: Moving
    let fallback: Fallback
    let duration: Double
    let verticalReturn: CGFloat

    var body: some View {
        if let modifier = ClockRuntime.modifier(period: duration) {
            AnyView(opened(moving, modifier: modifier).offset(y: verticalReturn))
        } else {
            AnyView(fallback)
        }
    }

    private func opened<V: View, M: ViewModifier>(_ view: V, modifier: M) -> some View {
        view.modifier(modifier)
    }

    static var isAvailable: Bool { ClockRuntime.available }
}

@available(iOS 16.1, *)
private enum ClockRuntime {
    private static let log = Logger(subsystem: "SGLiveIsland", category: "clock")
    private static let type: (any Decodable.Type)? = {
        guard let t = _typeByName("9WidgetKit24_ClockHandRotationEffectV"),
              let d = t as? any Decodable.Type else {
            log.error("clock effect unavailable")
            return nil
        }
        return d
    }()

    static var available: Bool { type != nil }

    // 每个周期只解码一次；周期变了才重解。最多缓存最近一个，内存恒定。
    private static let lock = NSLock()
    private static var cachedPeriod: Double = .nan
    private static var cachedModifier: (any ViewModifier)?

    private struct Payload: Encodable {
        private enum Keys: String, CodingKey { case period, timeZone, anchor, honorIdealizedDate }
        let period: Double
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            // 负周期 = 反向转，文字自右向左走。
            try c.encode(-period, forKey: .period)
            try c.encode(TimeZone(secondsFromGMT: 0) ?? TimeZone.current, forKey: .timeZone)
            try c.encode(false, forKey: .honorIdealizedDate)
            var a = c.nestedUnkeyedContainer(forKey: .anchor)
            try a.encode(0.5)
            try a.encode(0.5)
        }
    }

    static func modifier(period: Double) -> (any ViewModifier)? {
        guard let decodable = type,
              period.isFinite, (0.2...120).contains(period) else { return nil }
        let key = (period * 100).rounded() / 100
        lock.lock()
        defer { lock.unlock() }
        if key == cachedPeriod { return cachedModifier }
        do {
            let data = try JSONEncoder().encode(Payload(period: key))
            let decoded = try JSONDecoder().decode(decodable, from: data)
            guard let modifier = decoded as? any ViewModifier else { return nil }
            cachedPeriod = key
            cachedModifier = modifier
            return modifier
        } catch {
            log.error("clock decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
