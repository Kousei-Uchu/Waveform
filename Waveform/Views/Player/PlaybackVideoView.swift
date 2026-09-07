//
//  PlaybackVideoView.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 1/9/2026.
//


import SwiftUI
import WaveformBackendKit

#if os(iOS)
import UIKit

/// Embeds a `PlaybackEngine.videoRenderView` in SwiftUI — the
/// engine-agnostic replacement for `AVKit.VideoPlayer(player:)`.
///
/// `MediaPlayerController.videoRenderView` can point at a *different*
/// underlying view after a crossfade swaps which engine is "active" (same
/// as it used to point at a different `AVPlayer` before). `updateUIView`
/// re-parents the new view into the same container rather than assuming
/// `makeUIView` will be called again, since SwiftUI reuses the container
/// across that swap.
public struct PlaybackVideoView: UIViewRepresentable {
    private let contentView: PlaybackPlatformView

    public init(contentView: PlaybackPlatformView) {
        self.contentView = contentView
    }

    public func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        embed(contentView, in: container)
        return container
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        guard uiView.subviews.first !== contentView else { return }
        embed(contentView, in: uiView)
    }

    private func embed(_ view: UIView, in container: UIView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

#else
import AppKit
import WaveformBackendKit

public struct PlaybackVideoView: NSViewRepresentable {
    private let contentView: PlaybackPlatformView

    public init(contentView: PlaybackPlatformView) {
        self.contentView = contentView
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true
        embed(contentView, in: container)
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard nsView.subviews.first !== contentView else { return }
        embed(contentView, in: nsView)
    }

    private func embed(_ view: NSView, in container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
#endif
