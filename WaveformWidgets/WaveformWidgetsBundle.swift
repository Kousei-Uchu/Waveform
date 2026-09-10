import WidgetKit
import SwiftUI

@main
struct WaveformWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PlaybackActivityWidget()
        NowPlayingWidget()
    }
}
