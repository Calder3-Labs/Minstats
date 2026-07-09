import SwiftUI

struct StatsMenuApp: App {
    @State private var model = StatsModel()

    var body: some Scene {
        MenuBarExtra {
            DetailView(model: model)
        } label: {
            Text(model.menuTitle)
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
