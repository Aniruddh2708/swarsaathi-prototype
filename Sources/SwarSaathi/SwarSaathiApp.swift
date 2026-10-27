import SwiftUI

@main
struct SwarSaathiApp: App {
    @StateObject private var scaleVM: ScaleViewModel
    private let engine: PitchEngine

    init() {
        let e = PitchEngine()
        engine = e
        _scaleVM = StateObject(wrappedValue: ScaleViewModel(engine: e))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScaleDiscoveryView(vm: scaleVM, engine: engine)
            }
            .tint(.swarPurple)
        }
    }
}
