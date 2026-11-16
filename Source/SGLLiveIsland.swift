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
@MainActor
@objc(SGLLiveIsland)
public final class SGLLiveIsland: NSObject {

    // MARK: - 插件符号

    private typealias LinesForTrackFn = @convention(c) (NSString) -> NSArray?
    private typealias PositionMsFn    = @convention(c) () -> Int
    private typealias LeadLineFn      = @convention(c) (NSArray, Int) -> Int
    private typealias PlayingTrackFn  = @convention(c) () -> NSString?
    private typealias RequestLyricsFn = @convention(c) (NSString) -> Void
    private typealias PlayerFn        = @convention(c) () -> AnyObject?
    private typealias LineTextFn      = @convention(c) (AnyObject) -> NSString?
    private typealias ColorFn         = @convention(c) () -> AnyObject?

    private static var fnLines: LinesForTrackFn?
    private static var fnPos: PositionMsFn?
    private static var fnLead: LeadLineFn?
    private static var fnTrack: PlayingTrackFn?
    private static var fnRequestLyrics: RequestLyricsFn?
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
        fnRequestLyrics = symbol("SGKaraokeRequestLyrics", RequestLyricsFn.self)
        fnPlayer = symbol("SGKaraokePlayer", PlayerFn.self)
        fnLineText = symbol("SGKaraokeLineText", LineTextFn.self)
        fnAccent = symbol("SGAccentColor", ColorFn.self)
        resolveBridge()
        linked = true
        diag("plugin symbols linked")
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
    private static var lastFailedKey: String?
    private static var retryAfter = Date.distantPast
    private static var lastLinesAttempt = Date.distantPast
    private static var noLyricsTrack: String?
    private static var pausedSince: Date?
    private static var pauseSuppressed = false

    // 发送串行化：最新状态覆盖，永远只有一个 Task。
    // generation 用来取消旧歌/旧状态尚未完成的异步发送，避免旧歌词复活活动。
    private static var generation = 0
    private static var pendingGeneration = 0
    private static var pendingKey: String?
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
        static let hidden       = "sgl.hidden"

        static var isOn: Bool { UserDefaults.standard.object(forKey: enabled) as? Bool ?? false }
        /// 设置页存的是选项索引（0...4），这里映射成真实秒数。
        static var autoHideSeconds: Int {
            switch UserDefaults.standard.object(forKey: autoHide) as? Int ?? 0 {
            case 1: return 5
            case 2: return 30
            case 3: return 60
            case 4: return 300
            default: return 0
            }
        }
        /// 隐藏岛内容但保留实时活动／锁屏。
        static var islandHidden: Bool { UserDefaults.standard.object(forKey: hidden) as? Bool ?? false }
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

    private static var observers: [NSObjectProtocol] = []
    private static var settingsFingerprint = ""

    private static func settingsKey() -> String {
        "\(Defaults.isOn)|\(Defaults.autoHideSeconds)|\(Defaults.hideOnPause)|\(Defaults.useArtworkColor)|\(Defaults.fontStep)|\(Defaults.smoothScroll)|\(Defaults.windowChars)|\(Defaults.tickInterval)|\(Defaults.islandHidden)"
    }

    /// 诊断日志：写在沙盒 Documents，可用沙盒穿透读回。
    /// 只在启动/关键状态变化时写，不随 tick 刷。
    static func diag(_ line: String) {
        let path = NSHomeDirectory() + "/Documents/sgl.log"
        let text = "\(Date()) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 64 * 1024 {
            try? fm.removeItem(atPath: path)
        }
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    @objc public static func start() {
        guard !started else { return }
        started = true
        diag("dylib start, iOS \(UIDevice.current.systemVersion)")
        settingsFingerprint = settingsKey()
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let key = settingsKey()
                guard key != settingsFingerprint else { return }
                settingsFingerprint = key
                lastSentKey = nil
                pauseSuppressed = false
                suppressedTrack = nil
                schedule()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SGKaraokeLinesDidChangeNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                cachedLines.removeAll(keepingCapacity: false)
                cachedInfo = nil
                lastLinesAttempt = .distantPast
                lastSentKey = nil
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                retryAfter = .distantPast
                lastFailedKey = nil
                lastSentKey = nil
                tick()
            }
        })
        schedule()
    }

    private static func schedule() {
        timer?.invalidate()
        timer = nil
        guard Defaults.isOn else {
            cachedLines.removeAll(keepingCapacity: false)
            cachedInfo = nil
            dropActivity()
            return
        }
        let t = Timer(timeInterval: Defaults.tickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - 主循环

    private static var samplePosition: Int?
    private static var sampleUptime: TimeInterval?
    private static var samplePaused = true
    private static var suppressedTrack: String?
    private static var lyricsRequests = 0
    private static var debugTag = ""
    private static var diagTrack: String?
    private static var diagLineIndex = -1

    private static func tick() {
        guard Defaults.isOn else { return }
        guard link() else {
            if retryAfter < Date() {
                retryAfter = Date().addingTimeInterval(5)
                diag("plugin symbols not available yet")
            }
            return
        }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let track = trackID(), !track.isEmpty,
              let pos = fnPos?(), pos >= 0, pos <= 604_800_000 else {
            if cachedTrack != nil {
                cachedTrack = nil
                cachedLines.removeAll(keepingCapacity: false)
                cachedInfo = nil
                samplePosition = nil
                sampleUptime = nil
                dropActivity()
            }
            return
        }
        if cachedTrack != track {
            lyricsRequests = 0
            diagLineIndex = -1
            dropActivity()
            cachedTrack = track
            cachedLines.removeAll(keepingCapacity: false)
            cachedInfo = nil
            cachedLineIndex = -1
            lastLinesAttempt = .distantPast
            pausedSince = nil
            pauseSuppressed = false
            suppressedTrack = nil
            samplePosition = nil
            sampleUptime = nil
        }
        // 用户主动划掉的活动不在同一首歌中反复拉起。
        if activity?.activityState == .dismissed {
            suppressedTrack = track
            activity = nil
        }
        guard suppressedTrack != track else { return }
        if activity?.activityState == .ended {
            activity = nil
            lastSentKey = nil
        }
        // 状态未知时不假装播放，避免在不可靠的时间轴上滚动。
        guard let paused = isPaused() else { return }
        let transition = samplePosition == nil || paused != samplePaused
        var seeked = false
        if let previous = samplePosition, let lastUptime = sampleUptime {
            let expected = samplePaused ? 0 : (uptime - lastUptime) * 1000
            seeked = abs(Double(pos - previous) - expected) > 300
        }
        samplePosition = pos
        sampleUptime = uptime
        samplePaused = paused
        if paused {
            if pauseSuppressed { return }
            if pausedSince == nil { pausedSince = now }
            let expired = Defaults.autoHideSeconds > 0 &&
                now.timeIntervalSince(pausedSince ?? now) >= Double(Defaults.autoHideSeconds)
            if Defaults.hideOnPause || expired {
                pauseSuppressed = true
                dropActivity()
                return
            }
        } else {
            if pauseSuppressed { lastSentKey = nil }
            pausedSince = nil
            pauseSuppressed = false
        }
        if diagTrack != track {
            diagTrack = track
            let count = (fnLines?(track as NSString) as? [AnyObject])?.count ?? -1
            diag("track=\(track) lines=\(count)")
        }
        if cachedLines.isEmpty && now.timeIntervalSince(lastLinesAttempt) >= 3 {
            lastLinesAttempt = now
            // 插件只在有页面请求过歌词时才有行；后台/没人打开歌词页就一直是 nil。
            if lyricsRequests < 3, let ask = fnRequestLyrics {
                lyricsRequests += 1
                ask(track as NSString)
                diag("request lyrics #\(lyricsRequests) for \(track)")
            }
            if let raw = fnLines?(track as NSString), raw.count <= 4096 {
                cachedLines = raw as? [AnyObject] ?? []
            }
        }
        guard !cachedLines.isEmpty else {
            // 还没拿到歌词：把状态画到岛上，便于在不连设备的情况下定位。
            let tag = "L0 r\(lyricsRequests) p\(paused ? 1 : 0)"
            if debugTag != tag {
                debugTag = tag
                var info = LineInfo()
                info.text = ""
                info.times = []
                info.duration = 4
                info.lineStart = now
                info.paused = paused
                info.debug = tag
                deliver(info)
            }
            return
        }
        let idx = fnLead?(cachedLines as NSArray, pos) ?? -1
        guard idx >= 0, idx < cachedLines.count else {
            if cachedInfo != nil {
                cachedInfo = nil
                cachedLineIndex = -1
                let tag = "L\(cachedLines.count) i-1"
                if debugTag != tag {
                    debugTag = tag
                    var info = LineInfo()
                    info.text = ""
                    info.times = []
                    info.duration = 4
                    info.lineStart = now
                    info.paused = paused
                    info.debug = tag
                    deliver(info)
                }
            }
            return
        }
        if idx != cachedLineIndex || cachedInfo == nil {
            cachedInfo = parse(line: cachedLines[idx], lines: cachedLines, index: idx, posMs: pos)
            cachedLineIndex = idx
            lastSentKey = nil
        }
        if let info = cachedInfo, diagLineIndex != idx {
            diagLineIndex = idx
            diag("idx=\(idx) dur=\(String(format: "%.2f", info.duration)) chars=\(info.text.count) times=\(info.times.count) text=\(info.text.prefix(24))")
        }
        let key = "\(track)#\(idx)#\(paused)"
        if key == lastFailedKey && now < retryAfter { return }
        guard key != lastSentKey || transition || seeked else { return }
        guard var info = cachedInfo, !info.text.isEmpty || !info.debug.isEmpty else { return }
        // 每次暂停、恢复、seek 都按播放器位置重新锚定，避免累计暂停时间。
        let startMs = int(cachedLines[idx], "start") ?? pos
        let elapsed = max((Double(pos) - Double(startMs)) / 1000, 0)
        info.lineStart = now.addingTimeInterval(-elapsed)
        info.paused = paused
        lastSentKey = key
        deliver(info)
    }

    /// 所有 KVC 经过 Bootstrap.m 的 @try/@catch；即使第三方对象的
    /// getter 异常或版本字段缺失，也只返回 nil，不把 Spotify 一起带崩。
    private static func value(_ obj: AnyObject?, _ key: String) -> AnyObject? {
        SGLLiveIslandSafeValue(obj, key) as AnyObject?
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
        var debug = ""
    }

    private static func parse(line: AnyObject, lines: [AnyObject], index: Int, posMs: Int) -> LineInfo {
        var info = LineInfo()
        guard let nso = line as? NSObject else { return info }
        let startMs = int(nso, "start") ?? posMs
        var endMs = int(nso, "end") ?? startMs
        let words = array(nso, "words") ?? []
        // 限制解析工作量和 UTF-8 字节，恶意/损坏的歌词不触发无限分配。
        var bytes = 0
        for w in words.prefix(256) {
            guard let raw = string(w, "text"), !raw.isEmpty else { continue }
            let bounded = String(raw.prefix(128))
            let ws = int(w, "start") ?? startMs
            let we = int(w, "end") ?? ws
            let base = max(0, min(3600, (Double(ws) - Double(startMs)) / 1000))
            let span = max(0, min(3600, (Double(we) - Double(ws)) / 1000))
            // joined 描述的是「与前一个词连接」，不是后面是否加空格。
            if !info.text.isEmpty && !(bool(w, "joined") ?? false) && bytes < 767 {
                info.text.append(" ")
                info.times.append(max(info.times.last ?? 0, base))
                bytes += 1
            }
            let n = max(bounded.count, 1)
            for (i, c) in bounded.enumerated() {
                let count = String(c).utf8.count
                guard bytes + count <= 768, info.times.count < 128 else { break }
                info.text.append(c)
                let t = base + span * Double(i) / Double(n)
                info.times.append((max(info.times.last ?? 0, t) * 1000).rounded() / 1000)
                bytes += count
            }
            endMs = max(endMs, we)
            if bytes >= 768 || info.times.count >= 128 { break }
        }
        if endMs <= startMs {
            let next = index + 1 < lines.count ? int(lines[index + 1], "start") : nil
            info.duration = next.map { max(0.5, min(3600, (Double($0) - Double(startMs)) / 1000)) } ?? 4
        } else {
            info.duration = max(0.5, min(3600, (Double(endMs) - Double(startMs)) / 1000))
        }
        if info.text.isEmpty, let f = fnLineText, let line = f(nso) {
            info.text = (line as String).trimmingCharacters(in: .whitespacesAndNewlines)
            info.times = []
        }
        if let last = info.times.last { info.duration = max(info.duration, last + 0.05) }
        // 本次需求仅单行，避免给扩展发送未展示的下一行与整首歌词。
        return info
    }

    // MARK: - 下发（单 Task 串行，最新覆盖）

    private static func deliver(_ info: LineInfo) {
        let state = SGLyricsAttributes.ContentState(
            line: info.text,
            nextLine: info.next,
            title: "",
            artist: info.text.isEmpty
                ? (info.debug.isEmpty ? "L\(cachedLines.count)" : info.debug)
                : "",
            paused: info.paused,
            lineStart: info.lineStart,
            wordTimes: info.times,
            lineDuration: info.duration,
            pausedAt: info.paused ? Date() : nil,
            fontStep: Defaults.fontStep,
            windowChars: Defaults.windowChars,
            useArtworkColor: Defaults.useArtworkColor,
            islandHidden: Defaults.islandHidden,
            refreshTime: Defaults.refreshTime,
            smoothScroll: Defaults.smoothScroll,
            accent: accentHex(trackID: cachedTrack)
        )
        let stale: Date? = info.paused && Defaults.autoHideSeconds > 0
            ? Date().addingTimeInterval(TimeInterval(Defaults.autoHideSeconds))
            : nil

        // ActivityKit 的状态预算有限；不把任意长歌词交给系统编码。
        guard let data = try? JSONEncoder().encode(state), data.count <= 3584 else {
            lastFailedKey = lastSentKey
            retryAfter = Date().addingTimeInterval(30)
            lastSentKey = nil
            return
        }
        pendingState = state
        pendingStale = stale
        pendingKey = lastSentKey
        pendingGeneration = generation
        drain()
    }

    private static var endRequested = false

    private static func drain() {
        guard !sending else { return }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            while endRequested || pendingState != nil {
                if endRequested {
                    endRequested = false
                    let old = activity
                    activity = nil
                    if let old { await old.end(nil, dismissalPolicy: .immediate) }
                    continue
                }
                guard let state = pendingState else { continue }
                let stale = pendingStale
                let key = pendingKey
                let epoch = pendingGeneration
                pendingState = nil
                pendingStale = nil
                pendingKey = nil
                guard epoch == generation, Defaults.isOn else { continue }
                await send(state, stale: stale, key: key, epoch: epoch)
            }
        }
    }

    @MainActor
    private static func send(_ state: SGLyricsAttributes.ContentState,
                             stale: Date?, key: String?, epoch: Int) async {
        let content = ActivityContent(state: state, staleDate: stale)
        if let a = activity, a.activityState == .active || a.activityState == .stale {
            await a.update(content)
            return
        }
        // 这里不假定后台音频资格允许 request，授权/前后台失败走退避。
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active,
              !(bridgeIsShowing?() ?? false) else {
            lastFailedKey = key
            retryAfter = Date().addingTimeInterval(10)
            if lastSentKey == key { lastSentKey = nil }
            return
        }
        do {
            let newActivity = try Activity.request(
                attributes: SGLyricsAttributes(), content: content, pushType: nil)
            guard epoch == generation, Defaults.isOn else {
                await newActivity.end(nil, dismissalPolicy: .immediate)
                return
            }
            activity = newActivity
            lastFailedKey = nil
            retryAfter = .distantPast
        } catch {
            lastFailedKey = key
            retryAfter = Date().addingTimeInterval(10)
            if lastSentKey == key { lastSentKey = nil }
            log.error("request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func dropActivity() {
        generation &+= 1
        pendingState = nil
        pendingStale = nil
        pendingKey = nil
        lastSentKey = nil
        lastFailedKey = nil
        retryAfter = .distantPast
        endRequested = true
        drain()
    }

    // MARK: - 主题色

    private static func accentHex(trackID: String?) -> String {
        guard Defaults.useArtworkColor else { return SGLyricsAttributes.ContentState.defaultAccent }
        // 只认与当前曲目匹配的封面；未就绪/不匹配时用默认色，绝不拿上一首冒充。
        if let track = trackID, !track.isEmpty,
           let hex = SGLArtworkHex(track), hex.count == 6 {
            return hex
        }
        return SGLyricsAttributes.ContentState.defaultAccent
    }
}
