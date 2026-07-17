// EditorVideoOutputView.swift
// Aspect-safe recovery surface for EditorView. AVPlayerLayer can reject a live mixed-format
// AVVideoComposition even while AVPlayerItemVideoOutput continues producing the correctly
// composed pixel buffers. This renderer fans those frames out to the inline and fullscreen
// surfaces without ever presenting the transform-free composition.

import SwiftUI
import AVFoundation
import CoreImage
import QuartzCore
import UIKit

@MainActor
final class EditorVideoOutputRenderer {
    private weak var player: AVPlayer?
    private weak var output: AVPlayerItemVideoOutput?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let surfaces = NSHashTable<EditorVideoOutputSurface>.weakObjects()
    private var displayLink: CADisplayLink?

    func configure(player: AVPlayer, output: AVPlayerItemVideoOutput) {
        self.player = player
        self.output = output
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        startDisplayLinkIfNeeded()
        renderCurrentFrameIfAvailable()
    }

    func attach(_ surface: EditorVideoOutputSurface) {
        surface.renderer = self
        surfaces.add(surface)
        startDisplayLinkIfNeeded()
        renderCurrentFrameIfAvailable()
    }

    func detach(_ surface: EditorVideoOutputSurface) {
        surfaces.remove(surface)
        if surfaces.allObjects.isEmpty { stopDisplayLink() }
    }

    func reset() {
        player = nil
        output = nil
        for surface in surfaces.allObjects { surface.display(image: nil) }
        stopDisplayLink()
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil, !surfaces.allObjects.isEmpty else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        renderCurrentFrameIfAvailable(hostTime: link.targetTimestamp)
    }

    private func renderCurrentFrameIfAvailable(hostTime: CFTimeInterval? = nil) {
        guard let player, let output else { return }
        let itemTime: CMTime
        if let hostTime, player.rate != 0 {
            itemTime = output.itemTime(forHostTime: hostTime)
        } else {
            itemTime = player.currentTime()
        }
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        for surface in surfaces.allObjects { surface.display(image: cgImage) }
    }
}

struct EditorVideoOutputView: UIViewRepresentable {
    let renderer: EditorVideoOutputRenderer

    func makeUIView(context: Context) -> EditorVideoOutputSurface {
        let view = EditorVideoOutputSurface()
        renderer.attach(view)
        return view
    }

    func updateUIView(_ uiView: EditorVideoOutputSurface, context: Context) {
        renderer.attach(uiView)
    }

    static func dismantleUIView(_ uiView: EditorVideoOutputSurface, coordinator: ()) {
        uiView.renderer?.detach(uiView)
        uiView.renderer = nil
    }

}

@MainActor
final class EditorVideoOutputSurface: UIView {
    weak var renderer: EditorVideoOutputRenderer?
    private let imageLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.masksToBounds = true
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageLayer.frame = bounds
        imageLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
    }

    func display(image: CGImage?) {
        imageLayer.contents = image
    }
}
