import Foundation

/// 与 UI 和 ActivityKit 无关，时间轴算法可以离线回归。
enum LyricMotion {
    static func position(starts: [Double], duration: Double, elapsed: Double,
                         count: Int) -> Double {
        guard count > 0, count <= 128, elapsed.isFinite,
              duration.isFinite, duration > 0 else { return 0 }
        let t = max(0, min(elapsed, duration))
        guard starts.count == count else {
            return min(Double(count), t / duration * Double(count))
        }
        // 损坏/降序数据不能用于二分，也不能转成数组索引。
        var previous = 0.0
        for x in starts {
            guard x.isFinite, x >= previous, x <= duration else { return 0 }
            previous = x
        }
        guard t >= starts[0] else { return 0 }
        if t >= duration { return Double(count) }
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        let i = max(0, lo - 1)
        let end = i + 1 < count ? starts[i + 1] : duration
        let span = end - starts[i]
        guard span > 0 else { return Double(i) }
        let fraction = min(1, max(0, (t - starts[i]) / span))
        return min(Double(count), Double(i) + fraction)
    }

    static func clampedOffset(_ offset: Double, textWidth: Double,
                              viewportWidth: Double) -> Double {
        guard offset.isFinite, textWidth.isFinite, viewportWidth.isFinite else { return 0 }
        return min(max(0, offset), max(0, textWidth - max(0, viewportWidth)))
    }
}
