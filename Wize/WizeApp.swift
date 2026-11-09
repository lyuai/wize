import SwiftUI
import BackgroundTasks

enum BackgroundFeedRefresh {
    static let identifier = "com.lyuai.wize.feed-refresh"

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: ReaderModel.autoRefreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@main
struct WizeApp: App {
    @StateObject private var reader: ReaderModel
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WIZE_VISUAL_FIXTURE"] == "1" {
            _reader = StateObject(wrappedValue: ReaderModel(source: ReadingFixtureSource()))
        } else {
            _reader = StateObject(wrappedValue: ReaderModel())
        }
        #else
        _reader = StateObject(wrappedValue: ReaderModel())
        #endif
    }
    var body: some Scene {
        WindowGroup { ReaderView().environmentObject(reader) }
            .backgroundTask(.appRefresh(BackgroundFeedRefresh.identifier)) {
                BackgroundFeedRefresh.scheduleNext()
                await reader.performBackgroundAppRefresh()
            }
    }
}
