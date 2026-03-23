import AVFoundation
import Foundation

@MainActor
final class AudioContextPlayer {
    private var player: AVPlayer?
    private var boundaryObserver: Any?
    private var onFinish: (() -> Void)?

    func play(
        url: URL,
        from start: TimeInterval,
        to end: TimeInterval,
        onFinish: (() -> Void)? = nil
    ) {
        stop(notify: false)

        let safeStart = max(0, start)
        let safeEnd = max(safeStart + 0.25, end)

        let player = AVPlayer(url: url)
        self.player = player
        self.onFinish = onFinish

        let endTime = CMTime(seconds: safeEnd, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }

        let startTime = CMTime(seconds: safeStart, preferredTimescale: 600)
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                self?.player?.play()
            }
        }
    }

    func stop() {
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        if let boundaryObserver, let player {
            player.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil

        player?.pause()
        player = nil

        let completion = onFinish
        onFinish = nil

        if notify {
            completion?()
        }
    }
}
