import SwiftUI

struct ReadingStatsView: View {
    @ObservedObject var statsService = ReadingStatsService.shared
    @State private var refreshTick = 0
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent("Today") {
                    Text(TimeFormatting.format(statsService.todayListeningTime))
                }
                .accessibilityLabel("Listening time today: \(TimeFormatting.format(statsService.todayListeningTime))")

                LabeledContent("This Week") {
                    Text(TimeFormatting.format(statsService.thisWeekListeningTime))
                }
                .accessibilityLabel("Listening time this week: \(TimeFormatting.format(statsService.thisWeekListeningTime))")

                LabeledContent("All Time") {
                    Text(TimeFormatting.format(statsService.stats.totalListeningSeconds))
                }
                .accessibilityLabel("Total listening time: \(TimeFormatting.format(statsService.stats.totalListeningSeconds))")
            } header: {
                Text("Listening Time")
                    .accessibilityAddTraits(.isHeader)
            }

            Section {
                LabeledContent("Current Streak") {
                    Text("\(statsService.currentStreak) \(statsService.currentStreak == 1 ? "day" : "days")")
                }
                .accessibilityLabel("Current listening streak: \(statsService.currentStreak) days")

                LabeledContent("Books Finished This Year") {
                    Text("\(statsService.booksFinishedThisYear)")
                }
                .accessibilityLabel("\(statsService.booksFinishedThisYear) books finished this year")

                LabeledContent("Books Finished All Time") {
                    Text("\(statsService.stats.finishedBooks.count)")
                }
                .accessibilityLabel("\(statsService.stats.finishedBooks.count) books finished all time")
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
}
