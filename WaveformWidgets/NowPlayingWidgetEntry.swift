//
//  NowPlayingWidgetEntry.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 10/9/2026.
//


import WidgetKit
import SwiftUI

struct NowPlayingWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot?
    let configuration: NowPlayingWidgetConfigIntent
}

/// A single-entry-per-reload timeline: this widget has no way to predict
/// what track will be playing in five minutes, so it doesn't try to.
/// Every real update instead comes from the app explicitly calling
/// `WidgetCenter.shared.reloadTimelines(ofKind:)` whenever
/// `NowPlayingWidgetSync` writes a fresh `NowPlayingSnapshot` — a track
/// change, a play/pause, or an `AudioPlaybackIntent` firing from this
/// very widget. `.never` below means "don't also poll on a schedule," not
/// "never updates."
struct NowPlayingWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NowPlayingWidgetEntry {
        NowPlayingWidgetEntry(date: Date(), snapshot: .placeholder, configuration: NowPlayingWidgetConfigIntent())
    }

    func snapshot(for configuration: NowPlayingWidgetConfigIntent, in context: Context) async -> NowPlayingWidgetEntry {
        let snapshot = context.isPreview ? .placeholder : NowPlayingStore.read()
        return NowPlayingWidgetEntry(date: Date(), snapshot: snapshot, configuration: configuration)
    }

    func timeline(for configuration: NowPlayingWidgetConfigIntent, in context: Context) async -> Timeline<NowPlayingWidgetEntry> {
        let entry = NowPlayingWidgetEntry(date: Date(), snapshot: NowPlayingStore.read(), configuration: configuration)
        return Timeline(entries: [entry], policy: .never)
    }
}

struct NowPlayingWidget: Widget {
    let kind: String = NowPlayingStore.widgetKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: NowPlayingWidgetConfigIntent.self,
            provider: NowPlayingWidgetProvider()
        ) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    NowPlayingWidgetBackground(entry: entry)
                }
        }
        .configurationDisplayName("Now Playing")
        .description("Shows what's playing in Waveform with play/pause and skip controls.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}