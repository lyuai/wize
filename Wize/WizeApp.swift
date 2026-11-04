import SwiftUI

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
    }
}
