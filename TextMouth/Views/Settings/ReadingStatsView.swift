import Combine
import SwiftUI

/// The Stats settings pane: how long the user has listened, and how many
/// books they have finished.
///
/// Every figure is read at one instant (`ReadingStatsFigures`), so the
/// tiles agree with one another, and each tile's words come from
/// `ReadingStatsTile`, which words a figure once for the screen and for
/// VoiceOver alike.
///
/// The figures stay live while a book plays (TODO C07). Listening reaches
/// the saved statistics only at each checkpoint, a minute apart, and the
/// service's getters add the open session's time since then, so the pane
/// reads every figure afresh each time its body is evaluated: when the
/// statistics change, and at each refresh tick in between. A tick changes
/// nothing but the tiles' words. Each tile keeps its identity, so SwiftUI
/// updates it in place and VoiceOver's cursor stays where the user left
/// it, and nothing is announced: the user hears the new figure on reading
/// the tile.
struct ReadingStatsView: View {
    /// Seconds between refresh ticks while the pane is shown.
    static let refreshInterval: TimeInterval = 30

    /// The statistics shown: the app's own, unless a test passes others.
    @ObservedObject private var statsService: ReadingStatsService

    /// The time now, read once each time the figures are read: the system
    /// clock, unless a test stands in its own.
    private let clock: @MainActor () -> Date

    /// The ticks that ask for the figures to be read again. Kept as state
    /// so the pane keeps one timer for as long as it is shown: the Settings
    /// window makes this view anew whenever a setting changes, and a timer
    /// made anew each time would start its interval over.
    @State private var refreshTicks: AnyPublisher<Void, Never>

    /// How many refresh ticks have arrived. Nothing shows the count: it is
    /// the one state a tick changes, and reading it is what lets a tick
    /// re-evaluate the body (see `currentFigures`).
    @State private var refreshCount = 0

    /// - Parameters:
    ///   - statsService: The statistics to show.
    ///   - clock: The time now, read each time the figures are read.
    ///   - refreshTicks: Ticks that refresh the figures. When nil, a timer
    ///     ticks every `refreshInterval` seconds.
    init(
        statsService: ReadingStatsService = .shared,
        clock: @escaping @MainActor () -> Date = { Date() },
        refreshTicks: AnyPublisher<Void, Never>? = nil
    ) {
        _statsService = ObservedObject(wrappedValue: statsService)
        self.clock = clock
        _refreshTicks = State(initialValue: refreshTicks ?? Self.timerTicks())
    }

    var body: some View {
        // One reading of every figure, shared by all the tiles.
        let figures = currentFigures
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
                    // Each book once, by the finish Books Finished counts,
                    // each row keyed by its own entry (TODO P07).
                    ForEach(statsService.stats.recentlyFinished()) { entry in
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
        .onReceive(refreshTicks) { _ in
            refreshCount += 1
        }
    }

    /// Every figure as of now, read at one instant.
    private var currentFigures: ReadingStatsFigures {
        // SwiftUI re-evaluates a body only when state the body read has
        // changed, and a tick changes nothing but this count, so reading it
        // here is what makes each tick refresh the figures. Until TODO C07
        // the count was never read: the ticks refreshed nothing, and the
        // pane advanced only when a checkpoint changed the statistics.
        _ = refreshCount
        return ReadingStatsFigures(service: statsService, at: clock())
    }

    /// A row for each of `tiles` showing `figures`. Each row is identified
    /// by its tile, never by its value, so new figures update it in place.
    private func tiles(_ tiles: [ReadingStatsTile], showing figures: ReadingStatsFigures) -> some View {
        ForEach(tiles) { tile in
            ReadingStatsTileRow(tile: tile, wording: tile.wording(for: figures))
        }
    }

    /// Ticks every `refreshInterval` seconds on the main run loop, in its
    /// common modes so the pane keeps refreshing while a menu is open.
    private static func timerTicks() -> AnyPublisher<Void, Never> {
        Timer.publish(every: refreshInterval, tolerance: TimerCoalescing.tolerance(forInterval: refreshInterval), on: .main, in: .common)
            .autoconnect()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}

/// One tile of the Stats pane: its title beside its value, and any detail
/// under the value, such as the books finished of each kind. VoiceOver
/// speaks the tile's wording, which holds the detail too, as its label.
struct ReadingStatsTileRow: View {
    /// The figure this row shows.
    let tile: ReadingStatsTile
    /// That figure's words at the latest reading.
    let wording: ReadingStatsTileWording

    var body: some View {
        LabeledContent(tile.title) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(wording.value)
                if let detail = wording.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityLabel(wording.accessibilityLabel)
        .accessibilityIdentifier(tile.accessibilityIdentifier)
    }
}
