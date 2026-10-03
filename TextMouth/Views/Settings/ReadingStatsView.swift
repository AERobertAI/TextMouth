import SwiftUI

/// The Stats settings pane: how long the user has listened, and how many
/// books they have finished.
///
/// Every figure is read at one instant (`ReadingStatsFigures`), so the
/// tiles agree with one another, and each tile's words come from
/// `ReadingStatsTile`, which words a figure once for the screen and for
/// VoiceOver alike.
struct ReadingStatsView: View {
    @ObservedObject var statsService = ReadingStatsService.shared
    @State private var refreshTick = 0
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        // One reading of every figure, shared by all the tiles.
        let figures = ReadingStatsFigures(service: statsService, at: Date())
        Form {
            Section {
                tiles(ReadingStatsTile.listeningTime, showing: figures)
            } header: {
                Text("Listening Time")
                    .accessibilityAddTraits(.isHeader)
            }

            Section {
                tiles(ReadingStatsTile.progress, showing: figures)
            } header: {
                Text("Progress")
                    .accessibilityAddTraits(.isHeader)
            }

            if !statsService.stats.finishedBooks.isEmpty {
                Section {
                    ForEach(statsService.stats.finishedBooks.suffix(10).reversed(), id: \.bookID) { entry in
                        HStack {
                            Text(entry.title)
                            Spacer()
                            Text(entry.dateFinished, style: .date)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(entry.title), finished \(entry.dateFinished, style: .date)")
                    }
                } header: {
                    Text("Recently Finished")
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .padding()
        .onReceive(refreshTimer) { _ in
            refreshTick += 1 // Force periodic refresh of time displays
        }
    }

    /// A row for each of `tiles` showing `figures`. Each row is identified
    /// by its tile, never by its value, so new figures update it in place.
    private func tiles(_ tiles: [ReadingStatsTile], showing figures: ReadingStatsFigures) -> some View {
        ForEach(tiles) { tile in
            ReadingStatsTileRow(tile: tile, wording: tile.wording(for: figures))
        }
    }
}

/// One tile of the Stats pane: its title beside its value. VoiceOver speaks
/// the tile's wording as its label.
struct ReadingStatsTileRow: View {
    /// The figure this row shows.
    let tile: ReadingStatsTile
    /// That figure's words at the latest reading.
    let wording: ReadingStatsTileWording

    var body: some View {
        LabeledContent(tile.title) {
            Text(wording.value)
        }
        .accessibilityLabel(wording.accessibilityLabel)
        .accessibilityIdentifier(tile.accessibilityIdentifier)
    }
}
