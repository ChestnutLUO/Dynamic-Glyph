import SwiftUI

@main
struct DynamicGlyphApp: App {
    init() {
        GearExportFiles.removeStale()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
