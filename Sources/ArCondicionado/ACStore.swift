import Foundation
import Security
import SwiftUI
import UserNotifications
import AppKit

// Valores de t_work_mode / t_fan_speed (nomes de propriedade confirmados pelo REA no libapp.so)
enum Mode: Int, CaseIterable {
    case fan = 0, heat = 1, cool = 2, dry = 3, auto = 4

    var label: String {
        switch self {
        case .fan: String(localized: "Ventilar")
        case .heat: String(localized: "Aquecer")
        case .cool: String(localized: "Resfriar")
        case .dry: String(localized: "Desumidificar")
        case .auto: String(localized: "Automático")
        }
    }
    var icon: String {
        switch self {
        case .fan: "fan"
        case .heat: "sun.max"
        case .cool: "snowflake"
        case .dry: "drop"
        case .auto: "arrow.triangle.2.circlepath"
        }
    }
}

enum FanSpeed: Int, CaseIterable {
    case auto = 0, low = 5, midLow = 6, medium = 7, midHigh = 8, high = 9

    var label: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .low: String(localized: "Baixa")
        case .midLow: String(localized: "Média-baixa")
        case .medium: String(localized: "Média")
        case .midHigh: String(localized: "Média-alta")
        case .high: String(localized: "Alta")
        }
    }
}

@MainActor
final class ACStore: ObservableObject {
    @Published var loggedIn = false
    @Published var busy = false
    @Published var error: String?
    @Published var devices: [Appliance] = []
    @Published var selectedId: String?
    @Published var lastUpdate: Date?

    private var api: ConnectLifeAPI?
    private var pollTask: Task<Void, Never>?
    private var pendingTemp: Task<Void, Never>?

    // Timer de desligamento (local: roda no Mac, persiste entre reinícios)
    @Published private(set) var offAt: Date?
    @Published private(set) var timerStart: Date?
    private var timerDeviceId: String?
    private var timerTask: Task<Void, Never>?
    private var sleepBlocker: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isPreview = false

    let minTemp = 16, maxTemp = 32

    /// Store com dados fictícios, usado só pra gerar snapshots da interface.
    init(preview status: [String: Int]) {
        loggedIn = true
        devices = [Appliance(id: "preview", puid: "preview", name: "Split", room: String(localized: "Quarto"),
                             typeCode: "009", featureCode: "", offline: false, status: status)]
        lastUpdate = Date()
        isPreview = true
    }

    init() {
        if let creds = Keychain.load() {
            api = ConnectLifeAPI(email: creds.email, password: creds.password)
            loggedIn = true
            startPolling()
        }
        restoreTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkTimer() }
        }
    }

    var device: Appliance? { devices.first { $0.id == selectedId } ?? devices.first }

    func value(_ key: String) -> Int? { device?.status[key] }
    var isOn: Bool { value("t_power") == 1 }
    var targetTemp: Int { value("t_temp") ?? 24 }
    var roomTemp: Int? { value("f_temp_in") }
    var mode: Mode { Mode(rawValue: value("t_work_mode") ?? 2) ?? .cool }
    var fan: FanSpeed { FanSpeed(rawValue: value("t_fan_speed") ?? 0) ?? .auto }

    var menuBarTitle: String {
        guard loggedIn, device != nil else { return "" }
        return isOn ? "\(targetTemp)°" : "off"
    }

    // MARK: - Sessão

    func login(email: String, password: String) async {
        busy = true; error = nil
        let candidate = ConnectLifeAPI(email: email, password: password)
        do {
            try await candidate.login()
            Keychain.save(email: email, password: password)
            api = candidate
            loggedIn = true
            startPolling()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    func logout() {
        Keychain.delete()
        pollTask?.cancel()
        api = nil; devices = []; loggedIn = false
    }

    func refresh() async {
        guard let api else { return }
        do {
            let all = try await api.appliances()
            let acs = all.filter { $0.typeCode == "009" }
            devices = acs.isEmpty ? all : acs
            if selectedId == nil { selectedId = devices.first?.id }
            lastUpdate = Date()
            error = nil
            if offAt != nil, let id = timerDeviceId,
               devices.first(where: { $0.id == id })?.status["t_power"] == 0 {
                cancelTimer() // desligaram por outro lugar
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: - Comandos (otimistas)

    func togglePower() {
        if isOn && offAt != nil { cancelTimer() }
        send(["t_power": isOn ? 0 : 1])
    }
    func setMode(_ m: Mode) { if m != mode { send(["t_work_mode": m.rawValue]) } }
    func setFan(_ f: FanSpeed) { if f != fan { send(["t_fan_speed": f.rawValue]) } }

    /// Propriedades liga/desliga que só existem em alguns modelos.
    func has(_ key: String) -> Bool { device?.status[key] != nil }
    func isActive(_ key: String) -> Bool { (value(key) ?? 0) != 0 }
    func toggle(_ key: String) { send([key: isActive(key) ? 0 : 1]) }

    /// Atualiza a UI na hora e só manda pra nuvem depois que o usuário para de mexer.
    func setTemp(_ t: Int) {
        let t = min(max(t, minTemp), maxTemp)
        apply(["t_temp": t])
        pendingTemp?.cancel()
        pendingTemp = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.push(["t_temp": t])
        }
    }

    private func send(_ props: [String: Int]) {
        apply(props)
        Task { await push(props) }
    }

    private func apply(_ props: [String: Int]) {
        guard let idx = devices.firstIndex(where: { $0.id == device?.id }) else { return }
        withAnimation(.snappy) {
            for (k, v) in props { devices[idx].status[k] = v }
        }
    }

    private func push(_ props: [String: Int]) async {
        guard let api, let d = device else { return }
        do {
            try await api.set(puid: d.puid, properties: props)
            error = nil
        } catch {
            self.error = error.localizedDescription
            await refresh() // desfaz o otimismo
        }
    }
}

// MARK: - Timer

extension ACStore {
    private enum Keys {
        static let offAt = "timer.offAt", start = "timer.start", device = "timer.device"
    }

    var timerActive: Bool { offAt != nil }

    /// 0…1 de quanto do timer já passou
    func timerProgress(at now: Date) -> Double {
        guard let offAt, let timerStart else { return 0 }
        let total = offAt.timeIntervalSince(timerStart)
        return total > 0 ? min(max(now.timeIntervalSince(timerStart) / total, 0), 1) : 1
    }

    func startTimer(minutes: Int) {
        guard let d = device else { return }
        let now = Date()
        timerStart = now
        offAt = now.addingTimeInterval(TimeInterval(minutes * 60))
        timerDeviceId = d.id
        persistTimer()
        armTimer()
        if !isPreview {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Adia o desligamento sem zerar o progresso.
    func extendTimer(minutes: Int) {
        guard let at = offAt else { return startTimer(minutes: minutes) }
        offAt = max(at, Date()).addingTimeInterval(TimeInterval(minutes * 60))
        persistTimer()
    }

    func cancelTimer() {
        offAt = nil; timerStart = nil; timerDeviceId = nil
        timerTask?.cancel(); timerTask = nil
        persistTimer()
        allowSleep()
    }

    fileprivate func restoreTimer() {
        let ud = UserDefaults.standard
        guard let at = ud.object(forKey: Keys.offAt) as? Date else { return }
        offAt = at
        timerStart = ud.object(forKey: Keys.start) as? Date ?? at
        timerDeviceId = ud.string(forKey: Keys.device)
        armTimer()
    }

    private func persistTimer() {
        guard !isPreview else { return }
        let ud = UserDefaults.standard
        ud.set(offAt, forKey: Keys.offAt)
        ud.set(timerStart, forKey: Keys.start)
        ud.set(timerDeviceId, forKey: Keys.device)
    }

    private func armTimer() {
        timerTask?.cancel()
        preventSleep()
        // checa a cada 15 s em vez de um único sleep longo: sobrevive a o Mac dormir/acordar
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkTimer()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    fileprivate func checkTimer() {
        guard let offAt, Date() >= offAt else { return }
        let id = timerDeviceId
        cancelTimer()
        guard !isPreview, let api,
              let target = devices.first(where: { $0.id == id }) ?? device else { return }
        if let idx = devices.firstIndex(where: { $0.id == target.id }) {
            devices[idx].status["t_power"] = 0
        }
        Task {
            do {
                try await api.set(puid: target.puid, properties: ["t_power": 0])
                notify(String(localized: "Ar desligado pelo timer"),
                       String(localized: "\(target.room.isEmpty ? target.name : target.room) foi desligado."))
            } catch {
                self.error = error.localizedDescription
                notify(String(localized: "Falha no timer"),
                       String(localized: "Não consegui desligar o ar: \(error.localizedDescription)"))
            }
            await refresh()
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Impede o Mac de dormir por inatividade enquanto o timer está ativo.
    private func preventSleep() {
        guard sleepBlocker == nil, !isPreview else { return }
        sleepBlocker = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled], reason: "Timer do ar-condicionado")
    }

    private func allowSleep() {
        if let b = sleepBlocker { ProcessInfo.processInfo.endActivity(b) }
        sleepBlocker = nil
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "dev.local.ArCondicionado"

    static func save(email: String, password: String) {
        delete()
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: email,
            kSecValueData: Data(password.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> (email: String, password: String)? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let item = out as? [CFString: Any],
              let email = item[kSecAttrAccount] as? String,
              let data = item[kSecValueData] as? Data else { return nil }
        return (email, String(decoding: data, as: UTF8.self))
    }

    static func delete() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}
