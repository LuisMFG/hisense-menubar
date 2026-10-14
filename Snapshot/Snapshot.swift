import AppKit
import SwiftUI

// Gera as imagens do README com dados fictícios (não fala com a nuvem).
// Uso: ./snapshot.sh [pasta]   — padrão: docs/

@MainActor func store(_ status: [String: Int], timer: Int? = nil) -> ACStore {
    let s = ACStore(preview: status)
    if let timer { s.startTimer(minutes: timer) }
    return s
}

let cool: [String: Int] = ["t_power": 1, "t_temp": 21, "f_temp_in": 28, "t_work_mode": 2, "t_fan_speed": 0,
                           "t_super": 1, "t_up_down": 0, "t_eco": 0, "t_sleep": 0]
let heat: [String: Int] = ["t_power": 1, "t_temp": 26, "f_temp_in": 18, "t_work_mode": 1, "t_fan_speed": 9,
                           "t_super": 0, "t_up_down": 1, "t_eco": 0, "t_sleep": 0]
let dry: [String: Int] = ["t_power": 1, "t_temp": 24, "f_temp_in": 26, "t_work_mode": 3, "t_fan_speed": 6,
                          "t_super": 0, "t_up_down": 0, "t_eco": 1, "t_sleep": 1]
let off: [String: Int] = ["t_power": 0, "t_temp": 23, "f_temp_in": 25, "t_work_mode": 2, "t_fan_speed": 0,
                          "t_super": 0, "t_up_down": 0, "t_eco": 0, "t_sleep": 0]

struct Panel: View {
    let store: ACStore
    var body: some View {
        RootView()
            .environmentObject(store)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }
}

/// Fundo tipo wallpaper do macOS
struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.24), Color(red: 0.03, green: 0.04, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.25, green: 0.45, blue: 0.95).opacity(0.35), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.25).opacity(0.22), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 700)
        }
    }
}

@MainActor func write<V: View>(_ view: V, _ path: String) {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .darkAqua)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print(path)
}

@main enum Snapshot {
    @MainActor static func main() {
        let out = CommandLine.arguments.dropFirst().first ?? "docs"
        _ = NSApplication.shared
        SnapshotMode.isOn = true

        write(HStack(alignment: .top, spacing: 36) {
            Panel(store: store(cool))
            Panel(store: store(heat, timer: 90))
            Panel(store: store(dry))
        }
        .padding(56)
        .background(Backdrop()), "\(out)/hero.png")

        for (name, s, t) in [("cool", cool, nil), ("heat", heat, 90), ("dry", dry, nil), ("off", off, nil)] as [(String, [String: Int], Int?)] {
            write(Panel(store: store(s, timer: t)).padding(32).background(Backdrop()), "\(out)/\(name).png")
        }
    }
}
