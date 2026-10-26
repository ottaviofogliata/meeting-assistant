import SwiftUI
import AVFoundation

/// A native layer keeps the video surface independent of SwiftUI's AVKit bridge.
/// Playback and seeking use the same AVPlayer as the meeting's audio controls.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> VideoSurface { VideoSurface(player: player) }
    func updateNSView(_ view: VideoSurface, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
    final class VideoSurface: NSView {
        let playerLayer = AVPlayerLayer()
        init(player: AVPlayer) {
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.player = player; playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer = playerLayer
        }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); playerLayer.frame = bounds }
    }
}
