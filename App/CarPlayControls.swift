import Foundation
import MediaPlayer
import UIKit

/// Buttons CarWithin can press on the iPhone's behalf. Raw values are the browser message names.
enum CarPlayControl: String, CaseIterable {
    case home, back, select, knobPrevious, knobNext
    case previous, playPause, next
    case siri, hookSwitch

    var title: String {
        switch self {
        case .home: "主页"
        case .back: "返回"
        case .select: "选择"
        case .knobPrevious: "上一项"
        case .knobNext: "下一项"
        case .previous: "上一曲"
        case .playPause: "播放/暂停"
        case .next: "下一曲"
        case .siri: "Siri"
        case .hookSwitch: "接听/挂断"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .back: "chevron.backward"
        case .select: "smallcircle.filled.circle"
        case .knobPrevious: "chevron.up"
        case .knobNext: "chevron.down"
        case .previous: "backward.fill"
        case .playPause: "playpause.fill"
        case .next: "forward.fill"
        case .siri: "mic.fill"
        case .hookSwitch: "phone.fill"
        }
    }
}

/// A finger in normalized display coordinates (0…1). `id` is unique per source while held.
struct TouchPoint: Equatable { let id: Int; let x: Double; let y: Double }

/// Keeps each finger in one HID slot from press to release. Several sources (this iPhone,
/// browser viewers) share the two CarPlay slots; a finger beyond the free slots is ignored.
/// A released finger is reported up at its last position, never at (0,0), which would first
/// drag it into the corner.
struct TouchSlots {
    private struct Held { let source: String; let id: Int; var x: Double; var y: Double }
    private var slots: [Held?]
    init(count: Int) { slots = Array(repeating: nil, count: count) }

    /// Replaces every finger of `source` with `points` and returns the report contents:
    /// (slot, x, y, down) for each slot that is or just was in use.
    mutating func update(source: String, points: [TouchPoint]) -> [(slot: Int, x: Double, y: Double, down: Bool)] {
        var released: [(Int, Held)] = []
        for (slot, held) in slots.enumerated() {
            guard let held, held.source == source, !points.contains(where: { $0.id == held.id }) else { continue }
            released.append((slot, held)); slots[slot] = nil
        }
        for point in points {
            if let slot = slots.firstIndex(where: { $0?.source == source && $0?.id == point.id }) {
                slots[slot]?.x = point.x; slots[slot]?.y = point.y
            } else if let free = slots.firstIndex(where: { $0 == nil }) {
                slots[free] = Held(source: source, id: point.id, x: point.x, y: point.y)
            }
        }
        var report = slots.enumerated().compactMap { slot, held in held.map { (slot, $0.x, $0.y, true) } }
        report += released.map { ($0.0, $0.1.x, $0.1.y, false) }
        return report
    }

    var isEmpty: Bool { slots.allSatisfy { $0 == nil } }
    mutating func reset() { slots = Array(repeating: nil, count: slots.count) }
}

/// 把车把蓝牙媒体键（AVRCP）重映射成 CarPlay 焦点导航 HID 注入。
/// 默认只在春风仪表输出期间接管，避免抢占其他场景的 now-playing。
/// 原理：iPhone 把 AVRCP 命令派给当前 now-playing App，所以先声明 now-playing 再转发。
final class MediaKeyBridge {
    static let shared = MediaKeyBridge()

    private var tokens: [(command: MPRemoteCommand, token: Any)] = []
    private(set) var isRunning = false
    var onControl: ((CarPlayControl) -> Void)?
    var onLog: ((String) -> Void)?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            let center = MPRemoteCommandCenter.shared()
            // 车把媒体键重映射成 CarPlay 焦点导航：
            // 上一曲 = 焦点上移，下一曲 = 焦点下移，播放/暂停 = 确认，长按上一曲 = 主页，长按下一曲 = 返回。
            self.install(center.previousTrackCommand, "上一曲键", .knobPrevious)
            self.install(center.nextTrackCommand, "下一曲键", .knobNext)
            self.install(center.playCommand, "播放键", .select)
            self.install(center.pauseCommand, "暂停键", .select)
            self.install(center.togglePlayPauseCommand, "播放/暂停键", .select)
            self.install(center.seekBackwardCommand, "长按上一曲", .home)
            self.install(center.seekForwardCommand, "长按下一曲", .back)
            self.install(center.skipBackwardCommand, "快退键", nil)
            self.install(center.skipForwardCommand, "快进键", nil)
            self.install(center.changePlaybackPositionCommand, "进度拖动", nil)
            self.claimNowPlaying()
            UIApplication.shared.beginReceivingRemoteControlEvents()
            self.onLog?("车把按键已接管：上一曲/下一曲 = 移动焦点，播放暂停 = 确认，音量键仍调系统音量")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tokens.forEach { $0.command.removeTarget($0.token) }
            self.tokens.removeAll()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if #available(iOS 13.0, *) { MPNowPlayingInfoCenter.default().playbackState = .stopped }
            UIApplication.shared.endReceivingRemoteControlEvents()
            self.onLog?("蓝牙媒体键接管已停止")
        }
    }

    private func install(_ command: MPRemoteCommand, _ name: String, _ control: CarPlayControl?) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] _ in
            guard let self else { return .success }
            if let control {
                self.onLog?("收到车把按键：\(name) → 注入 CarPlay「\(control.title)」")
                self.onControl?(control)
            } else {
                self.onLog?("收到车把按键：\(name)（暂未映射）")
            }
            return .success
        }
        tokens.append((command, token))
    }

    private func claimNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "CarWithin",
            MPMediaItemPropertyArtist: "CarPlay",
            MPMediaItemPropertyPlaybackDuration: 0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        info[MPMediaItemPropertyAlbumTitle] = "仪表投屏"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if #available(iOS 13.0, *) { MPNowPlayingInfoCenter.default().playbackState = .playing }
    }
}