import Foundation
import Security
import SwiftUI

// Valores de t_work_mode / t_fan_speed (nomes de propriedade confirmados pelo REA no libapp.so)
enum Mode: Int, CaseIterable {
    case fan = 0, heat = 1, cool = 2, dry = 3, auto = 4

    var label: String {
        switch self {
        case .fan: "Ventilar"
        case .heat: "Aquecer"
        case .cool: "Resfriar"
        case .dry: "Desumidificar"
        case .auto: "Automático"
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
        case .auto: "Auto"
        case .low: "Baixa"
        case .midLow: "Média-baixa"
        case .medium: "Média"
        case .midHigh: "Média-alta"
        case .high: "Alta"
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


    let minTemp = 16, maxTemp = 32

    /// Store com dados fictícios, usado só pra gerar snapshots da interface.
    init(preview status: [String: Int]) {
        loggedIn = true
        devices = [Appliance(id: "preview", puid: "preview", name: "Split", room: "Quarto",
                             typeCode: "009", featureCode: "", offline: false, status: status)]
        lastUpdate = Date()
    }

    init() {
        if let creds = Keychain.load() {
            api = ConnectLifeAPI(email: creds.email, password: creds.password)
            loggedIn = true
            startPolling()
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

    func togglePower() { send(["t_power": isOn ? 0 : 1]) }
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
