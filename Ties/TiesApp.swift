import SwiftUI
import TiesCore

@main
struct TiesApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Ties \(TiesCore.version)")
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}
