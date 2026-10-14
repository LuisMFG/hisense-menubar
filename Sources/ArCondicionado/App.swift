import SwiftUI

@main
struct ArCondicionadoApp: App {
    @StateObject private var store = ACStore()

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.isOn ? "air.conditioner.horizontal.fill" : "air.conditioner.horizontal")
                if !store.menuBarTitle.isEmpty {
                    Text(store.menuBarTitle).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
