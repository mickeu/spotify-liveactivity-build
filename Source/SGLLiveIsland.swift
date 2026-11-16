// SGLLiveIsland.swift — 主 App 侧的灵动岛歌词驱动
//
// 设计（决定资源占用与流畅度）：
//   · 主 App 只在「换行 / 暂停变化 / 换歌」时推一次，不参与逐帧滚动；
//   · 每帧位移由 extension 自己的 TimelineView 本地计算，不跨进程；
//   · lineStart 只在换行那一刻由「播放位置 - 行起始毫秒」反推并缓存，
//     暂停/恢复不重算，避免行首随时间漂移。
//
// 只读 spotifyglass 导出的符号，不改它的任何状态。
// 内存：只持有一首歌的行数组 + 当前行解析结果，换歌即替换；发送走单 Task 串行，不堆积。

import Foundation
import UIKit
import ActivityKit
import ObjectiveC
import os

@available(iOS 16.2, *)
@objc(SGLLiveIsland)
public final class SGLLiveIsland: NSObject {

    // MARK: - 插件符号

    private typealias LinesForTrackFn = @convention(c) (NSString) -> NSArray?
    private typealias PositionMsFn    = @convention(c) () -> Int
    private typealias LeadLineFn      = @convention(c) (NSArray, Int) -> Int
    private typealias PlayingTrackFn  = @convention(c) () -> NSString?
    private typealias PlayerFn        = @convention(c) () -> AnyObject?
    private typealias LineTextFn      = @convention(c) (AnyObject) -> NSString?
    private typealias ColorFn         = @convention(c) () -> AnyObject?

    private static var fnLines: LinesForTrackFn?
    private static var fnPos: PositionMsFn?
    private static var fnLead: LeadLineFn?
    private static var fnTrack: PlayingTrackFn?
    private static var fnPlayer: PlayerFn?
    private static var fnLineText: LineTextFn?
    private static var fnAccent: ColorFn?
    private static var linked = false

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle = rtldDefault, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// LoadControl 扫 Frameworks 的顺序不保证，所以每次 tick 都试，直到成功。
    @discardableResult
    private static func link() -> Bool {
        if linked { return true }
        guard let a = symbol("SGKaraokeLinesForTrack", LinesForTrackFn.self),
              let b = symbol("SGKaraokePositionMs", PositionMsFn.self),
              let c = symbol("SGKaraokeLeadLine", LeadLineFn.self) else { return false }
        fnLines = a
        fnPos = b
        fnLead = c
        fnTrack = symbol("SGKaraokePlayingTrack", PlayingTrackFn.self)
        fnPlayer = symbol("SGKaraokePlayer", PlayerFn.self)
        fnLineText = symbol("SGKaraokeLineText", LineTextFn.self)
        fnAccent = symbol("SGAccentColor", ColorFn.self)
        resolveBridge()
        linked = true
        log.info("linked")
        return true
    }

    /// 插件自己的 Live Activity 若已在跑，就不抢地盘，避免两张歌词卡并存。
    private static var bridgeIsShowing: (() -> Bool)?

    private static func resolveBridge() {
        guard let cls = NSClassFromString("SGLiveActivityBridge") else { return }
        let sel = NSSelectorFromString("isShowing")
        guard let method = class_getClassMethod(cls, sel) else { return }
        let imp = method_getImplementation(method)
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(imp, to: Getter.self)
        bridgeIsShowing = { getter(cls, sel) }
    }

    // MARK: - 状态（全部有界）

    private static let log = Logger(subsystem: "sgliveisland", category: "main")
    private static var timer: Timer?
    private static var started = false
    private static var activity: Activity<SGLyricsAttributes>?

    private static var cachedTrack: String?
    private static var cachedLines: [AnyObject] = []
    private static var cachedLineIndex = -1
    private static var cachedInfo: LineInfo?
    private static var lastSentKey: String?
    private static var lastLinesAttempt = Date.distantPast
    private static var pausedSince: Date?
    private static var pauseSuppressed = false

    // 发送串行化：最新状态覆盖，永远只有一个 Task
    private static var pendingState: SGLyricsAttributes.ContentState?
    private static var pendingStale: Date?
    private static var sending = false

    // MARK: - 设置（extension 读不到 UserDefaults，全部随状态下发）

    private enum Defaults {
        static let enabled      = "sgl.enabled"
        static let autoHide     = "sgl.autoHide"
        static let hideOnPauseKey = "sgl.hideOnPause"
        static let artworkColor = "sgl.artworkColor"
        static let tick         = "sgl.tick"
        static let width        = "sgl.width"
        static let fontSize     = "sgl.fontSize"
        static let smooth       = "sgl.smooth"

        static var isOn: Bool { UserDefaults.standard.object(forKey: enabled) as? Bool ?? true }
        static var autoHideSeconds: Int { UserDefaults.standard.object(forKey: autoHide) as? Int ?? 30 }
        static var hideOnPause: Bool { UserDefaults.standard.object(forKey: hideOnPauseKey) as? Bool ?? false }
        static var useArtworkColor: Bool { UserDefaults.standard.object(forKey: artworkColor) as? Bool ?? true }
        static var fontStep: Int { UserDefaults.standard.object(forKey: fontSize) as? Int ?? 1 }
        static var smoothScroll: Bool { UserDefaults.standard.object(forKey: smooth) as? Bool ?? true }
        /// extension 的刷新周期；暂停时放宽，省电
        static var refreshTime: Double { smoothScroll ? 0.2 : 1.0 }
        static var tickInterval: Double {
            let v = UserDefaults.standard.object(forKey: tick) as? Double ?? 0.5
            return min(max(v, 0.25), 2.0)
        }
        static var windowChars: Int {
            (UserDefaults.standard.object(forKey: width) as? Int ?? 0) == 1 ? 12 : 8
        }
    }

    // MARK: - 生命周期

    @objc public static func start() {
        guard !started else { return }
        started = true
        DispatchQueue.main.async {
            schedule()
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { _ in schedule() }
        }
    }

    private static func schedule() {
        timer?.invalidate()
        timer = nil
        guard Defaults.isOn else {
            dropActivity()
            return
        }
        let t = Timer(timeInterval: Defaults.tickInterval, repeats: true) { _ in tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - 主循环

    private static func tick() {
        guard Defaults.isOn, link() else { return }
        guard let track = trackID(), !track.isEmpty else { return }
        guard let pos = fnPos?(), pos >= 0 else { return }

        if cachedTrack != track {
            cachedTrack = track
            cachedLines = []
            cachedLineIndex = -1
            cachedInfo = nil
            lastSentKey = nil
            pauseSuppressed = false
            pausedSince = nil
        }

        // 歌词可能晚于曲目信息到达：空的时候每 3 秒重取一次，不做每 tick 查询
        if cachedLines.isEmpty {
            if Date().timeIntervalSince(lastLinesAttempt) > 3 {
                lastLinesAttempt = Date()
                cachedLines = (fnLines?(track as NSString) as? [AnyObject]) ?? []
            }
            guard !cachedLines.isEmpty else { return }
        }

        let idx = fnLead?(cachedLines as NSArray, pos) ?? -1
        guard idx >= 0, idx < cachedLines.count else { return }

        let paused = isPaused() ?? false

        if paused {
            if pauseSuppressed { return }
            if pausedSince == nil { pausedSince = Date() }
            if Defaults.hideOnPause {
                pauseSuppressed = true
                dropActivity()
                return
            }
            if let since = pausedSince, Defaults.autoHideSeconds > 0,
               Date().timeIntervalSince(since) >= Double(Defaults.autoHideSeconds) {
                pauseSuppressed = true
                dropActivity()
                return
            }
        } else {
            pausedSince = nil
            pauseSuppressed = false
        }

        // 换行才重新解析并定 lineStart（避免暂停期间行首漂移）
        if idx != cachedLineIndex || cachedInfo == nil {
            let lineStartMs = int(cachedLines[idx], "start") ?? pos
            let elapsed = max(Double(pos - lineStartMs) / 1000.0, 0)
            var info = parse(line: cachedLines[idx], lines: cachedLines, index: idx, posMs: pos)
            info.lineStart = Date().addingTimeInterval(-elapsed)
            cachedInfo = info
            cachedLineIndex = idx
        }

        let key = "\(track)#\(idx)#\(paused)"
        guard key != lastSentKey else { return }
        lastSentKey = key

        guard var info = cachedInfo else { return }
        info.paused = paused
        deliver(info)
    }

    /// 安全 KVC：不存在的 key 会让 value(forKey:) 抛异常直接闪退，
    /// 所以先确认 getter 真的在，再取值。
    private static func value(_ obj: AnyObject?, _ key: String) -> AnyObject? {
        guard let nso = obj as? NSObject else { return nil }
        guard nso.responds(to: NSSelectorFromString(key)) else { return nil }
        return nso.value(forKey: key)
    }

    private static func int(_ obj: AnyObject?, _ key: String) -> Int? {
        value(obj, key) as? Int
    }

    private static func string(_ obj: AnyObject?, _ key: String) -> String? {
        value(obj, key) as? String
    }

    private static func bool(_ obj: AnyObject?, _ key: String) -> Bool? {
        value(obj, key) as? Bool
    }

    private static func array(_ obj: AnyObject?, _ key: String) -> [AnyObject]? {
        value(obj, key) as? [AnyObject]
    }

    private static func trackID() -> String? {
        guard let f = fnTrack, let s = f() else { return nil }
        return s as String
    }

    private static func isPaused() -> Bool? {
        guard let f = fnPlayer, let player = f() else { return nil }
        guard let st = value(player, "state") as AnyObject? else { return nil }
        return bool(st, "isPaused")
    }

    // MARK: - 解析一行（只在换行时调用）

    private struct LineInfo {
        var text = ""
        var next = ""
        var times: [Double] = []
        var duration: Double = 0
        var lineStart = Date()
        var paused = false
    }

    private static func parse(line: AnyObject, lines: [AnyObject], index: Int, posMs: Int) -> LineInfo {
        var info = LineInfo()
        guard let nso = line as? NSObject else { return info }

        let startMs = int(nso, "start") ?? posMs
        var endMs = int(nso, "end") ?? 0
        let words = array(nso, "words") ?? []

        if words.isEmpty {
            info.text = lineText(nso)
        } else {
            var chars = ""
            var times: [Double] = []
            chars.reserveCapacity(48)
            times.reserveCapacity(48)

            for w in words {
                guard let wt = string(w, "text"), !wt.isEmpty else { continue }
                let ws = int(w, "start") ?? startMs
                let we = int(w, "end") ?? ws
                let joined = bool(w, "joined") ?? false
                let base = Double(ws - startMs) / 1000.0
                let span = max(Double(we - ws) / 1000.0, 0.02)
                let n = wt.count
                for (i, c) in wt.enumerated() {
                    chars.append(c)
                    times.append(base + span * Double(i) / Double(n))
                }
                if !joined {
                    chars.append(" ")
                    times.append(base + span)
                }
                if we > endMs { endMs = we }
            }
            info.text = chars
            info.times = times
        }

        if endMs <= startMs {
            let nextStart = index + 1 < lines.count ? (int(lines[index + 1], "start") ?? 0) : 0
            endMs = nextStart > startMs ? nextStart : startMs + 4000
        }
        info.duration = max(Double(endMs - startMs) / 1000.0, 0.5)
        if let last = info.times.last, last > info.duration { info.duration = last + 0.3 }

        if index + 1 < lines.count {
            info.next = lineText(lines[index + 1] as AnyObject)
        }
        return info
    }

    private static func lineText(_ line: AnyObject) -> String {
        if let f = fnLineText, let s = f(line) { return s as String }
        guard line is NSObject else { return "" }
        let words = array(line, "words") ?? []
        var out = ""
        for w in words {
            out += string(w, "text") ?? ""
            if !(bool(w, "joined") ?? false) { out += " " }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 下发（单 Task 串行，最新覆盖）

    private static func deliver(_ info: LineInfo) {
        let state = SGLyricsAttributes.ContentState(
            line: info.text,
            nextLine: info.next,
            title: "",
            artist: "",
            paused: info.paused,
            lineStart: info.lineStart,
            wordTimes: info.times,
            lineDuration: info.duration,
            pausedAt: info.paused ? Date() : nil,
            fontStep: Defaults.fontStep,
            windowChars: Defaults.windowChars,
            useArtworkColor: Defaults.useArtworkColor,
            refreshTime: Defaults.refreshTime,
            smoothScroll: Defaults.smoothScroll,
            accent: accentHex()
        )
        let stale: Date? = info.paused && Defaults.autoHideSeconds > 0
            ? Date().addingTimeInterval(TimeInterval(Defaults.autoHideSeconds))
            : nil

        pendingState = state
        pendingStale = stale
        guard !sending else { return }
        sending = true
        Task { @MainActor in
            while let s = pendingState {
                let st = pendingStale
                pendingState = nil
                pendingStale = nil
                await send(s, stale: st)
            }
            sending = false
        }
    }

    @MainActor
    private static func send(_ state: SGLyricsAttributes.ContentState, stale: Date?) async {
        let content = ActivityContent(state: state, staleDate: stale)
        if let a = activity ?? Activity<SGLyricsAttributes>.activities.first {
            activity = a
            await a.update(content)
            return
        }
        if let showing = bridgeIsShowing, showing() { return }

        do {
            activity = try await Activity.request(
                attributes: SGLyricsAttributes(), content: content, pushType: nil)
            log.info("activity started")
        } catch {
            log.error("request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func dropActivity() {
        Task { @MainActor in
            guard let a = activity ?? Activity<SGLyricsAttributes>.activities.first else { return }
            await a.end(nil, dismissalPolicy: .immediate)
            activity = nil
        }
    }

    // MARK: - 主题色

    private static func accentHex() -> String {
        guard Defaults.useArtworkColor else { return SGLyricsAttributes.ContentState.defaultAccent }
        guard let f = fnAccent, let color = f() as? UIColor else {
            return SGLyricsAttributes.ContentState.defaultAccent
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return SGLyricsAttributes.ContentState.defaultAccent
        }
        func clamp(_ v: CGFloat) -> UInt32 {
            UInt32(max(0, min(255, (v * 255).rounded())))
        }
        return String(format: "%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}
