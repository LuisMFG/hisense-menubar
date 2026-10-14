import SwiftUI

// MARK: - Tema

private let offTint = Color(white: 0.55)

extension Mode {
    var tint: Color {
        switch self {
        case .cool: Color(red: 0.31, green: 0.70, blue: 1.00)
        case .heat: Color(red: 1.00, green: 0.54, blue: 0.24)
        case .dry: Color(red: 0.25, green: 0.83, blue: 0.76)
        case .fan: Color(red: 0.72, green: 0.78, blue: 0.86)
        case .auto: Color(red: 0.61, green: 0.48, blue: 1.00)
        }
    }
    var activeLabel: String {
        switch self {
        case .cool: String(localized: "Resfriando")
        case .heat: String(localized: "Aquecendo")
        case .dry: String(localized: "Desumidificando")
        case .fan: String(localized: "Ventilando")
        case .auto: String(localized: "Automático")
        }
    }
    var shortLabel: String {
        switch self {
        case .cool: String(localized: "Frio")
        case .heat: String(localized: "Calor")
        case .dry: String(localized: "Seco")
        case .fan: String(localized: "Vento")
        case .auto: String(localized: "Auto")
        }
    }
}

extension FanSpeed {
    /// 0…1, usado pra força do fluxo de ar
    var strength: Double { self == .auto ? 0.6 : Double(rawValue - 4) / 5 }
    /// voltas por segundo do ícone do ventilador
    var rps: Double { self == .auto ? 1.0 : 0.4 + Double(rawValue - 5) * 0.45 }
}

extension View {
    /// Ícone "respirando" enquanto o modo está ativo (breathe no macOS 15+, pulse antes).
    @ViewBuilder func breathing(_ active: Bool) -> some View {
        if #available(macOS 15, *) {
            symbolEffect(.breathe, options: .repeat(.continuous), isActive: active)
        } else {
            symbolEffect(.pulse, options: .repeating, isActive: active)
        }
    }
}

// MARK: - Raiz

struct RootView: View {
    @EnvironmentObject var store: ACStore

    private var tint: Color { store.isOn ? store.mode.tint : offTint }

    var body: some View {
        Group {
            if store.loggedIn {
                ControlView()
            } else {
                LoginView()
            }
        }
        .frame(width: 312)
        .background {
            ZStack {
                Glass()
                Color.black.opacity(0.5)
                RadialGradient(colors: [tint.opacity(store.isOn ? 0.30 : 0.06), .clear],
                               center: UnitPoint(x: 0.5, y: 0.36), startRadius: 0, endRadius: 280)
            }
            .animation(.easeInOut(duration: 0.6), value: tint)
        }
        .environment(\.colorScheme, .dark)
        .tint(tint)
        .task { if store.loggedIn { await store.refresh() } }
    }
}

// MARK: - Controle principal

struct ControlView: View {
    @EnvironmentObject var store: ACStore

    private var tint: Color { store.isOn ? store.mode.tint : offTint }

    var body: some View {
        VStack(spacing: 18) {
            header

            if store.device == nil {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.error ?? String(localized: "Buscando aparelhos…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                ZStack(alignment: .top) {
                    // o ar sai da aleta do split e desce até o dial
                    Airflow(color: tint, on: store.isOn, strength: store.fan.strength)
                        .frame(width: 280, height: 230)
                        .offset(y: 50)
                        .allowsHitTesting(false)
                    VStack(spacing: 0) {
                        ACUnitView(on: store.isOn, temp: store.targetTemp, tint: tint)
                        ThermostatDial(temp: store.targetTemp, range: store.minTemp...store.maxTemp,
                                       on: store.isOn, tint: tint, mode: store.mode,
                                       roomTemp: store.roomTemp, onChange: store.setTemp)
                    }
                }

                VStack(spacing: 10) {
                    ModePicker(selected: store.mode, on: store.isOn, onSelect: store.setMode)
                    FanMeter(selected: store.fan, on: store.isOn, tint: tint, onSelect: store.setFan)
                    extras
                    TimerRow(tint: tint)
                }
                .disabled(!store.isOn)
                .opacity(store.isOn ? 1 : 0.4)
            }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .animation(.snappy, value: store.isOn)
        .animation(.snappy, value: store.mode)
    }

    private var title: String {
        guard let d = store.device else { return String(localized: "Ar-condicionado") }
        return d.room.isEmpty ? d.name : d.room
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if store.devices.count > 1 {
                    Menu(title) {
                        ForEach(store.devices) { d in
                            Button(d.room.isEmpty ? d.name : "\(d.room) · \(d.name)") { store.selectedId = d.id }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.system(size: 15, weight: .semibold))
                } else {
                    Text(title).font(.system(size: 15, weight: .semibold))
                }
                HStack(spacing: 5) {
                    Circle().fill(store.isOn ? tint : Color.white.opacity(0.25)).frame(width: 6, height: 6)
                    Text(store.isOn ? store.mode.activeLabel : String(localized: "Desligado"))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
            PowerButton(on: store.isOn, tint: tint, action: store.togglePower)
                .disabled(store.device == nil)
        }
    }

    /// Chips para funções extras, mostrados só quando o modelo reporta a propriedade.
    @ViewBuilder private var extras: some View {
        let chips: [(key: String, icon: String, label: String)] = [
            ("t_super", "bolt.fill", String(localized: "Turbo")),
            ("t_up_down", "arrow.up.and.down", String(localized: "Swing")),
            ("t_eco", "leaf.fill", String(localized: "Eco")),
            ("t_sleep", "moon.fill", String(localized: "Sono")),
        ].filter { store.has($0.key) }
        if !chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(chips, id: \.key) { c in
                    Chip(icon: c.icon, label: c.label, active: store.isActive(c.key), tint: tint) {
                        store.toggle(c.key)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let err = store.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(err).lineLimit(1).truncationMode(.tail)
            } else if let t = store.lastUpdate {
                Text("Atualizado \(t.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .keyboardShortcut("r")
            Menu {
                Button("Sair da conta") { store.logout() }
                Divider()
                Button("Fechar app") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Dial do termostato

struct ThermostatDial: View {
    let temp: Int
    let range: ClosedRange<Int>
    let on: Bool
    let tint: Color
    let mode: Mode
    let roomTemp: Int?
    let onChange: (Int) -> Void

    private let size: CGFloat = 184
    private let line: CGFloat = 14
    private let sweep = 0.75          // 270°
    private let startAngle = 135.0    // começa embaixo à esquerda

    private var fraction: Double {
        Double(temp - range.lowerBound) / Double(range.upperBound - range.lowerBound)
    }

    var body: some View {
        ZStack {
            // brilho
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(on ? 0.30 : 0), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.42))
                .frame(width: size * 0.84)

            // marcações
            ForEach(range.lowerBound...range.upperBound, id: \.self) { t in
                let f = Double(t - range.lowerBound) / Double(range.upperBound - range.lowerBound)
                Capsule()
                    .fill(Color.white.opacity(t <= temp && on ? 0.5 : 0.14))
                    .frame(width: 1.5, height: t % 2 == 0 ? 6 : 3)
                    .offset(y: -(size / 2 + 12))
                    .rotationEffect(.degrees(startAngle + 90 + f * 270))
            }

            // trilho
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
                .frame(width: size, height: size)

            // progresso
            Circle()
                .trim(from: 0, to: sweep * max(fraction, 0.001))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.35), tint],
                                    center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(270 * max(fraction, 0.05))),
                    style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
                .frame(width: size, height: size)
                .shadow(color: tint.opacity(on ? 0.5 : 0), radius: 8)

            // botão de arrastar
            Circle()
                .fill(.white)
                .frame(width: line + 8, height: line + 8)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                .offset(x: size / 2)
                .rotationEffect(.degrees(startAngle + fraction * 270))
                .opacity(on ? 1 : 0)

            // centro
            VStack(spacing: 0) {
                Text("ALVO")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.tertiary)
                HStack(alignment: .top, spacing: 0) {
                    Text("\(temp)")
                        .font(.system(size: 68, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(temp)))
                    Text("°")
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .padding(.top, 6)
                }
                .foregroundStyle(on ? .primary : .tertiary)
                if let roomTemp {
                    Label("\(roomTemp)° agora", systemImage: "house")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            // − / +
            HStack {
                StepButton(symbol: "minus") { step(to: temp - 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Spacer()
                StepButton(symbol: "plus") { step(to: temp + 1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
            }
            .frame(width: size * 0.62)
            .offset(y: size / 2 - 8)
            .disabled(!on)
            .opacity(on ? 1 : 0.3)
        }
        .frame(width: size + 40, height: size + 30)
        .contentShape(Circle())
        .gesture(dragGesture)
        .animation(.snappy(duration: 0.25), value: temp)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard on else { return }
                let c = CGPoint(x: (size + 40) / 2, y: (size + 30) / 2)
                let dx = g.location.x - c.x, dy = g.location.y - c.y
                // ignora toques no miolo (onde ficam o número e os botões)
                guard hypot(dx, dy) > size * 0.32 else { return }
                var a = atan2(dy, dx) * 180 / .pi - startAngle
                a = (a + 720).truncatingRemainder(dividingBy: 360)
                if a > 270 { a = a > 315 ? 0 : 270 }
                let t = range.lowerBound + Int((a / 270 * Double(range.upperBound - range.lowerBound)).rounded())
                if t != temp { step(to: t) }
            }
    }

    /// Muda a temperatura com um "clique" no trackpad a cada grau (mais forte nas pontas).
    private func step(to t: Int) {
        let t = min(max(t, range.lowerBound), range.upperBound)
        guard t != temp else { Haptics.edge(); return }
        (t == range.lowerBound || t == range.upperBound) ? Haptics.edge() : Haptics.tick()
        onChange(t)
    }
}

private struct StepButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Liga/desliga

private struct PowerButton: View {
    let on: Bool
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(on ? .black : .white.opacity(0.8))
                .frame(width: 40, height: 40)
                .background(Circle().fill(on ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.white.opacity(0.08))))
                .overlay(Circle().stroke(.white.opacity(on ? 0.25 : 0.08), lineWidth: 1))
                .shadow(color: on ? tint.opacity(0.55) : .clear, radius: 10)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(on ? String(localized: "Desligar") : String(localized: "Ligar"))
    }
}

// MARK: - Modo

private struct ModePicker: View {
    let selected: Mode
    let on: Bool
    let onSelect: (Mode) -> Void
    @Namespace private var ns

    private let order: [Mode] = [.cool, .heat, .dry, .fan, .auto]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(order, id: \.self) { m in
                Button { onSelect(m) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: m.icon).font(.system(size: 13, weight: .semibold))
                            .breathing(on && m == selected)
                        Text(m.shortLabel).font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(m == selected ? m.tint : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background {
                        if m == selected {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(m.tint.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(m.tint.opacity(0.35)))
                                .matchedGeometryEffect(id: "sel", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(m.label)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.05)))
    }
}

// MARK: - Ventilação

private struct FanMeter: View {
    let selected: FanSpeed
    let on: Bool
    let tint: Color
    let onSelect: (FanSpeed) -> Void

    private let levels: [FanSpeed] = [.low, .midLow, .medium, .midHigh, .high]

    var body: some View {
        HStack(spacing: 10) {
            SpinningFan(rps: on ? selected.rps : 0)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)

            Button { onSelect(.auto) } label: {
                Text("AUTO")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(selected == .auto ? .black : .secondary)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(selected == .auto ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.07))))
            }
            .buttonStyle(.plain)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(levels.enumerated()), id: \.offset) { i, level in
                    let filled = selected != .auto && level.rawValue <= selected.rawValue
                    Button { onSelect(level) } label: {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.1)))
                            .frame(maxWidth: .infinity)
                            .frame(height: 8 + CGFloat(i) * 3.5)
                            .frame(height: 24, alignment: .bottom)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(level.label)
                }
            }

            Text(selected == .auto ? "" : selected.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.05)))
    }
}

// MARK: - Timer de desligamento

private struct TimerRow: View {
    @EnvironmentObject var store: ACStore
    let tint: Color

    private let presets: [(min: Int, label: String)] = [(30, "30m"), (60, "1h"), (120, "2h"), (240, "4h"), (480, "8h")]

    var body: some View {
        Group {
            if let offAt = store.offAt {
                active(offAt)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            } else {
                picker.transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.05)))
        .animation(.snappy, value: store.offAt)
    }

    private var picker: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("Desligar em")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 2)
            ForEach(presets, id: \.min) { p in
                Button { store.startTimer(minutes: p.min) } label: {
                    Text(p.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 29, height: 24)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Desligar o ar daqui a \(p.label)")
            }
        }
    }

    private func active(_ offAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: 1 - store.timerProgress(at: ctx.date))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(remaining(until: offAt, now: ctx.date))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text("Desliga às \(offAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.extendTimer(minutes: 30) } label: {
                    Text("+30m")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Adiar 30 minutos")
                Button(action: store.cancelTimer) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Cancelar timer")
            }
        }
    }

    private func remaining(until offAt: Date, now: Date) -> String {
        let s = max(Int(offAt.timeIntervalSince(now).rounded(.up)), 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Chips

private struct Chip: View {
    let icon: String
    let label: String
    let active: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
                    .symbolEffect(.bounce, value: active)
                Text(label).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .foregroundStyle(active ? .black : .secondary)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(Capsule().fill(active ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.06))))
            .overlay(Capsule().stroke(.white.opacity(active ? 0 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Login

struct LoginView: View {
    @EnvironmentObject var store: ACStore
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "air.conditioner.horizontal.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Mode.cool.tint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Mode.cool.tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Entrar na ConnectLife").font(.system(size: 14, weight: .semibold))
                    Text("A senha fica só no Keychain deste Mac.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                TextField("E-mail", text: $email)
                    .textContentType(.username)
                SecureField("Senha", text: $password)
                    .textContentType(.password)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)
            if let err = store.error {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Fechar") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button("Entrar", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(email.isEmpty || password.isEmpty || store.busy)
            }
            .font(.system(size: 12))
        }
        .padding(18)
    }

    private func submit() {
        Task { await store.login(email: email, password: password) }
    }
}
