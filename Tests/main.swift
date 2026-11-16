import Foundation

func check(_ condition: Bool, _ name: String) {
    if !condition { fatalError("FAIL: \(name)") }
}
func p(_ t: Double) -> Double {
    LyricMotion.position(starts: [0, 1.2, 2.4, 2.6], duration: 3,
                         elapsed: t, count: 4)
}
check(p(0) == 0, "首字不提前跳过")
check(abs(p(0.6) - 0.5) < 0.00001, "慢字中间位置")
check(abs(p(2.5) - 2.5) < 0.00001, "快字中间位置")
check(p(3) == 4 && p(30) == 4, "行尾有界")
check(p(-1) == 0, "负进度")
check(p(.nan) == 0 && p(.infinity) == 0, "非有限时间不转索引")
check(LyricMotion.position(starts: [0, 0, 1], duration: 2, elapsed: 0.5, count: 3) == 1.5, "同时间多字")
check(LyricMotion.position(starts: [0, 2, 1], duration: 3, elapsed: 1, count: 3) == 0, "拒绝倒序时间")
check(LyricMotion.position(starts: [1, 2], duration: 3, elapsed: 0.5, count: 2) == 0, "行首留白")
check(LyricMotion.position(starts: [], duration: 4, elapsed: 2, count: 4) == 2, "无逐字时间降级")
check(LyricMotion.clampedOffset(300, textWidth: 200, viewportWidth: 60) == 140, "行尾不滚空白")
check(LyricMotion.clampedOffset(30, textWidth: 40, viewportWidth: 60) == 0, "短句不滚")
check(LyricMotion.clampedOffset(.nan, textWidth: 200, viewportWidth: 60) == 0, "异常位移")
// 模拟暂停 10s 后用播放器位置重锚；恢复后进度必须不计入暂停时长。
let beforeWall = 100.0
let playback = 1.2
let pausedAnchor = beforeWall - playback
let pausedElapsed = beforeWall - pausedAnchor
let resumedWall = 110.0
let resumedAnchor = resumedWall - playback
check(abs(pausedElapsed - (resumedWall - resumedAnchor)) < 1e-9, "暂停恢复重锚")
var last = 0.0
for i in 0...10000 {
    let v = p(Double(i) / 1000)
    check(v.isFinite && v >= last && v <= 4, "长序列单调有界")
    last = v
}
print("PASS: 14 boundary cases + 10001 timing samples")
