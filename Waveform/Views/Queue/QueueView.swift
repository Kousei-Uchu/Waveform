import SwiftUI
import WaveformBackendKit

struct QueueView: View {
    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController

    var body: some View {
        NavigationStack {
            Group {
                if queue.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Queue is empty")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(Array(queue.entries.enumerated()), id: \.element.id) { index, entry in
                            QueueRow(entry: entry, isCurrent: index == queue.currentIndex)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    queue.jump(to: index)
                                    player.play()
                                }
                                .listRowBackground(Color.clear)
                        }
                        .onDelete { offsets in
                            for index in offsets.sorted(by: >) {
                                queue.remove(at: index)
                            }
                        }
                        .onMove { from, to in
                            queue.move(fromOffsets: from, toOffset: to)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    #if os(iOS)
                    .toolbar { EditButton() }
                    #endif
                }
            }
            .navigationTitle("Up Next")
            #if os(iOS)
            .containerBackground(.clear, for: .navigation)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            queue.toggleShuffle()
                        } label: {
                            Label(queue.isShuffled ? "Shuffle: On" : "Shuffle: Off", systemImage: "shuffle")
                        }
                        Picker("Repeat", selection: $queue.repeatMode) {
                            Text("Off").tag(RepeatMode.off)
                            Text("One").tag(RepeatMode.one)
                            Text("All").tag(RepeatMode.all)
                        }
                        Divider()
                        Button("Clear Queue", role: .destructive) {
                            queue.clear()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Queue Options")
                }
            }
        }
    }
}
