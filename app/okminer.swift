import SwiftUI
import AppKit

// MARK: - Throttle

/// XMRig has no throttle, so pause/resume the process with SIGSTOP/SIGCONT
/// every 100 ms, letting it run for `duty` of each period.
final class Throttler: @unchecked Sendable {
    private static let period = 0.1
    private let pid: pid_t
    private let queue = DispatchQueue(label: "okminer.throttle", qos: .userInteractive)
    private var timer: DispatchSourceTimer?   // only touched on `queue`
    private var duty: Double

    init(pid: pid_t, duty: Double) {
        self.pid = pid
        self.duty = duty
        queue.async { [self] in
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.period, leeway: .milliseconds(2))
            t.setEventHandler { [unowned self] in cycle() }
            t.resume()
            timer = t
        }
    }

    func setDuty(_ d: Double) { queue.async { [self] in duty = d } }

    /// Call before signalling the process to exit.
    func invalidate() {
        queue.sync {
            timer?.cancel()
            timer = nil
            kill(pid, SIGCONT)
        }
    }

    private func cycle() {
        kill(pid, SIGCONT)
        guard duty < 1 else { return }
        queue.asyncAfter(deadline: .now() + Self.period * duty) { [self] in
            if timer != nil && duty < 1 { kill(pid, SIGSTOP) }
        }
    }
}

// MARK: - Pools

/// A preset pool, or whatever was typed into Custom.
struct Pool: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String       // host:port
    let tls: Bool
    let statsPage: String?    // + wallet address

    static let customID = "custom"

    static let presets = [
        Pool(id: "oklahoma", name: "oklahoma.li", url: "pool.oklahoma.li:3333", tls: true,
             statsPage: "https://www.oklahoma.li/#/miner/"),
    ]

    static func custom(_ url: String, tls: Bool) -> Pool {
        let host = url.replacingOccurrences(of: #"^stratum\+(tcp|ssl)://"#, with: "", options: .regularExpression)
            .split(separator: ":").first.map(String.init) ?? url
        return Pool(id: customID, name: host, url: url, tls: tls, statsPage: nil)
    }

    /// host:port, optionally prefixed with stratum+tcp:// or stratum+ssl://
    static func looksValid(_ url: String) -> Bool {
        url.range(of: #"^(stratum\+(tcp|ssl)://)?[A-Za-z0-9.-]+:[0-9]{1,5}$"#, options: .regularExpression) != nil
    }
}

// MARK: - Miner process + stats

@MainActor
final class Miner: ObservableObject {
    @Published var isRunning = false
    @Published var status = "Ready to mine"
    @Published var statusKind = StatusKind.idle
    @Published var hashrate: Double?      // H/s, 10s average
    @Published var sharesGood = 0
    @Published var sharesTotal = 0
    @Published var uptime = 0

    private var process: Process?
    private var throttler: Throttler?
    private var pollTimer: Timer?
    private var sleepActivity: NSObjectProtocol?
    private var apiPort = 0
    private var apiToken = ""
    private var stoppingOnPurpose = false
    private var partialLine = ""
    private var lastError: String?
    private var poolName = ""
    /// xmrig takes ~10s to report a hashrate.
    private var awaitingFirstHashrate = false

    enum StatusKind { case idle, working, good, warning, error }

    /// Used when the wallet field is left empty.
    static let defaultWallet = "48KJ3jAyp7j7B2oU4p46VN4eDqcF2LGLufPg8ZJgmLeQKAvPa75KUgB5VQsQYbPtL7Fru6o75LMEoeWqcLoAjMP49Vi5iDi"

    static let defaultWorker = "okminer"

    struct Settings {
        var wallet: String
        var worker: String
        var pool: Pool
        var threads: Int
        var throttle: Int   // 10-100
    }

    static var binaryURL: URL? {
        Bundle.main.url(forResource: "xmrig", withExtension: nil)
    }

    func start(_ s: Settings) {
        guard !isRunning, let bin = Self.binaryURL else {
            if Self.binaryURL == nil { setStatus("The miner is missing from the app. Try rebuilding it.", .error) }
            return
        }
        apiPort = Int.random(in: 42000...48999)
        apiToken = UUID().uuidString

        let trimmed = s.wallet.trimmingCharacters(in: .whitespacesAndNewlines)
        let wallet = trimmed.isEmpty ? Self.defaultWallet : trimmed
        let trimmedWorker = s.worker.trimmingCharacters(in: .whitespacesAndNewlines)
        let worker = trimmedWorker.isEmpty ? Self.defaultWorker : trimmedWorker
        var args = [
            "--no-color",
            "-o", s.pool.url,
            "-u", wallet,
            "-p", worker,
            "-k",
            "--threads", String(s.threads),  // max-threads-hint is ignored on ARM
            "--http-host", "127.0.0.1",
            "--http-port", String(apiPort),
            "--http-access-token", apiToken,
            "--print-time", "30",
        ]
        if s.pool.tls { args.append("--tls") }

        let p = Process()
        p.executableURL = bin
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.didExit(code: proc.terminationStatus) }
        }

        hashrate = nil; sharesGood = 0; sharesTotal = 0; uptime = 0
        partialLine = ""; lastError = nil; awaitingFirstHashrate = false
        poolName = s.pool.name
        setStatus("Connecting to \(poolName)…", .working)
        do {
            try p.run()
        } catch {
            setStatus("Couldn't start the miner: \(error.localizedDescription)", .error)
            return
        }
        process = p
        isRunning = true
        throttler = Throttler(pid: p.processIdentifier, duty: Double(s.throttle) / 100)
        stoppingOnPurpose = false

        // don't idle-sleep while mining
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Mining Monero")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    func setThrottle(_ percent: Int) {
        throttler?.setDuty(Double(percent) / 100)
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        stoppingOnPurpose = true
        throttler?.invalidate(); throttler = nil  // a stopped process won't see SIGINT
        p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
    }

    /// Used on quit so the miner isn't left running.
    func stopBlocking() {
        guard let p = process, p.isRunning else { return }
        throttler?.invalidate(); throttler = nil
        p.interrupt()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    private func didExit(code: Int32) {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        throttler?.invalidate(); throttler = nil
        process = nil
        isRunning = false
        pollTimer?.invalidate(); pollTimer = nil
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a); sleepActivity = nil }
        if stoppingOnPurpose {
            setStatus("Stopped", .idle)
        } else {
            setStatus("The miner stopped unexpectedly" + (lastError.map { ": \($0)" } ?? " (code \(code))"), .error)
        }
    }

    private func setStatus(_ text: String, _ kind: StatusKind) {
        status = text
        statusKind = kind
    }

    /// Output arrives in arbitrary chunks, so buffer partial lines.
    private func consume(_ text: String) {
        let lines = (partialLine + text).components(separatedBy: "\n")
        partialLine = lines.last ?? ""
        lines.dropLast().forEach(handle)
    }

    /// Map xmrig log lines to a short status.
    private func handle(_ line: String) {
        if line.contains("use pool") {
            setStatus("Connected to \(poolName)", .good)
        } else if line.contains("init dataset") {
            setStatus("Getting ready to mine…", .working)
        } else if line.contains("READY threads") {
            awaitingFirstHashrate = true
            setStatus("Mining — measuring speed…", .working)
        } else if line.contains(" accepted (") {
            setStatus("Share accepted by the pool", .good)
        } else if line.contains(" rejected (") {
            setStatus("A share was rejected by the pool", .warning)
        } else if line.contains("no active pools") {
            setStatus("Can't reach the pool, retrying…", .warning)
        } else if let r = line.range(of: #"(connect|read|write|login|DNS) error"#, options: .regularExpression) {
            lastError = String(line[r.lowerBound...])
            setStatus("Connection problem, retrying…", .warning)
        }
    }

    private func poll() async {
        guard isRunning, let url = URL(string: "http://127.0.0.1:\(apiPort)/2/summary") else { return }
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let hr = json["hashrate"] as? [String: Any], let total = hr["total"] as? [Any] {
            hashrate = total.first as? Double
            if awaitingFirstHashrate, let h = hashrate, h > 0 {
                awaitingFirstHashrate = false
                setStatus("Mining", .good)
            }
        }
        if let r = json["results"] as? [String: Any] {
            sharesGood = r["shares_good"] as? Int ?? 0
            sharesTotal = r["shares_total"] as? Int ?? 0
        }
        uptime = json["uptime"] as? Int ?? uptime
    }
}

// MARK: - Palette

enum Mesa {
    static let ground   = dynamic(0xF3E9DA, 0x1F1612)
    static let card     = dynamic(0xFBF6EE, 0x2B1F18)
    static let inset    = dynamic(0xF1E6D5, 0x241A14)
    static let line     = dynamic(0xE2D1BA, 0x3E2D23)
    static let ink      = dynamic(0x3A2418, 0xF1E3CF)
    static let dust     = dynamic(0x8C6B55, 0xB89C84)
    static let clay     = dynamic(0xB4532A, 0xC9643A)
    static let redRock  = dynamic(0x8E3524, 0x9C3B28)
    static let sage     = dynamic(0x6E8250, 0xA2B27A)
    static let sky      = dynamic(0x5F8FA8, 0x8DB6CC)
    static let wheat    = dynamic(0xC98E2E, 0xE2B25E)
    static let cream    = Color(red: 0.99, green: 0.96, blue: 0.91)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

struct PillButtonStyle: ButtonStyle {
    var fill: Color
    var text: Color

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, fill: fill, text: text)
    }

    private struct Label: View {
        let configuration: Configuration
        let fill: Color
        let text: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .foregroundStyle(text)
                .background(Capsule().fill(fill))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
        }
    }
}

extension View {
    /// xmrig only reads these at startup.
    func lockedWhileMining(_ running: Bool) -> some View {
        self.disabled(running).opacity(running ? 0.4 : 1)
    }

    func mesaField() -> some View {
        self.textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Mesa.inset))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Mesa.line))
            .foregroundStyle(Mesa.ink)
    }
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject var miner: Miner

    @AppStorage("wallet") private var wallet = ""
    @AppStorage("workerName") private var worker = Miner.defaultWorker
    @AppStorage("pool") private var poolID = Pool.presets[0].id
    @AppStorage("customPool") private var customPool = ""
    @AppStorage("customPoolTLS") private var customPoolTLS = true
    @AppStorage("threads") private var threads = max(1, Self.cores / 2)
    @AppStorage("throttle") private var throttle = 100
    static let cores = ProcessInfo.processInfo.activeProcessorCount

    private var cpuThreads: Int { min(max(threads, 1), Self.cores) }

    private var trimmedWallet: String { wallet.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var trimmedCustomPool: String { customPool.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var pool: Pool {
        if poolID == Pool.customID { return .custom(trimmedCustomPool, tls: customPoolTLS) }
        return Pool.presets.first { $0.id == poolID } ?? Pool.presets[0]
    }

    private var poolLooksValid: Bool { poolID != Pool.customID || Pool.looksValid(trimmedCustomPool) }

    private var walletLooksValid: Bool {
        let w = trimmedWallet
        if w.isEmpty { return true }
        let b58 = CharacterSet(charactersIn: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        guard let first = w.first, first == "4" || first == "8" else { return false }
        return (w.count == 95 || w.count == 106) && w.unicodeScalars.allSatisfy(b58.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("okminer")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(Mesa.clay)
                .frame(height: 22)
                .padding(.leading, 4)
            header
            statusLine
            settings
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 20)
        .frame(width: 480)
        .background(Mesa.ground.ignoresSafeArea())
        .tint(Mesa.clay)
        .onAppear {
            // saved pool no longer offered
            if poolID != Pool.customID && !Pool.presets.contains(where: { $0.id == poolID }) {
                poolID = Pool.presets[0].id
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                hashrateText
                Text(miner.isRunning
                     ? "\(miner.sharesGood) share\(miner.sharesGood == 1 ? "" : "s") · \(formatUptime(miner.uptime))"
                     : "Not mining")
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Mesa.cream.opacity(0.8))
            }
            Spacer()
            Button(miner.isRunning ? "Stop" : "Start mining") {
                if miner.isRunning {
                    miner.stop()
                } else {
                    miner.start(.init(wallet: wallet, worker: worker, pool: pool,
                                      threads: cpuThreads, throttle: throttle))
                }
            }
            .buttonStyle(PillButtonStyle(fill: Mesa.cream, text: miner.isRunning ? Mesa.redRock : Mesa.clay))
            .disabled(!miner.isRunning && !(walletLooksValid && poolLooksValid))
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Mesa.clay, Mesa.redRock],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }

    private var hashrateText: some View {
        let h = miner.isRunning ? (miner.hashrate ?? 0) : 0
        let (value, unit) = h >= 1000 ? (String(format: "%.2f", h / 1000), "kH/s")
                          : (miner.isRunning && h == 0 ? "—" : String(format: "%.0f", h), "H/s")
        return (Text(value).font(.system(size: 46, weight: .bold, design: .rounded))
                + Text(" " + unit).font(.system(size: 18, weight: .semibold, design: .rounded)))
            .monospacedDigit()
            .foregroundStyle(Mesa.cream.opacity(miner.isRunning ? 1 : 0.6))
            .contentTransition(.numericText())
            .animation(.default, value: value)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(miner.status)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Mesa.dust)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(miner.status)
        }
        .padding(.horizontal, 4)
        .animation(.default, value: miner.status)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Pool", trailing: {
                Picker("", selection: $poolID) {
                    ForEach(Pool.presets) { Text($0.name).tag($0.id) }
                    Divider()
                    Text("Custom…").tag(Pool.customID)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(miner.isRunning)
            }) {
                if poolID == Pool.customID {
                    TextField("", text: $customPool, prompt: Text("host:port").foregroundColor(Mesa.dust))
                        .font(.system(size: 12, design: .monospaced))
                        .mesaField()
                        .disabled(miner.isRunning)
                    Toggle("Use TLS (encrypted connection)", isOn: $customPoolTLS)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Mesa.ink)
                        .disabled(miner.isRunning)
                    if !trimmedCustomPool.isEmpty && !poolLooksValid {
                        caption("Enter the pool as host:port, e.g. pool.example.com:3333.", color: Mesa.redRock)
                    } else if !customPoolTLS {
                        caption("Without TLS your wallet address and shares are sent unencrypted.")
                    }
                } else {
                    caption("\(pool.url) · TLS")
                }
            }
            .lockedWhileMining(miner.isRunning)

            section("Wallet address") {
                TextField("", text: $wallet, prompt: Text("Paste your Monero address").foregroundColor(Mesa.dust))
                    .font(.system(size: trimmedWallet.isEmpty ? 13 : 12, design: trimmedWallet.isEmpty ? .rounded : .monospaced))
                    .mesaField()
                    .disabled(miner.isRunning)
                if trimmedWallet.isEmpty {
                    caption("Empty: mining to the default address \(Miner.defaultWallet.prefix(8))…\(Miner.defaultWallet.suffix(6))")
                } else if !walletLooksValid {
                    caption("That doesn't look like a Monero address (95 characters, starts with 4 or 8).", color: Mesa.redRock)
                }
            }
            .lockedWhileMining(miner.isRunning)

            section("Worker name") {
                TextField("", text: $worker, prompt: Text(Miner.defaultWorker).foregroundColor(Mesa.dust))
                    .mesaField()
                    .disabled(miner.isRunning)
            }
            .lockedWhileMining(miner.isRunning)

            section("CPU cores", value: "\(cpuThreads) of \(Self.cores)") {
                Slider(value: Binding(get: { Double(cpuThreads) }, set: { threads = Int($0.rounded()) }),
                       in: 1...Double(max(Self.cores, 2)))
                    .disabled(miner.isRunning)
            }
            .lockedWhileMining(miner.isRunning)

            section("CPU throttle", value: "\(throttle)%") {
                Slider(value: Binding(get: { Double(throttle) },
                                      set: { throttle = Int(($0 / 5).rounded()) * 5; miner.setThrottle(throttle) }),
                       in: 10...100)
                caption(throttle == 100
                        ? "Full speed. Turn it down to run cooler and quieter, even while mining."
                        : "Mining \(throttle)% of the time. You can change this while mining.")
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Mesa.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Mesa.line))
    }

    /// Link to your stats page (custom pools don't have one).
    @ViewBuilder private var footer: some View {
        if let statsPage = pool.statsPage {
            Button {
                let address = trimmedWallet.isEmpty ? Miner.defaultWallet : trimmedWallet
                if let url = URL(string: statsPage + address) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 4) {
                    Text("Find your coins on \(pool.name)")
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Mesa.clay)
            }
            .buttonStyle(.plain)
            .onHover { inside in inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, value: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        section(title, trailing: {
            if let value {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Mesa.ink)
            }
        }, content: content)
    }

    private func section<Trailing: View, Content: View>(_ title: String,
                                                        @ViewBuilder trailing: () -> Trailing,
                                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(Mesa.dust)
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func caption(_ text: String, color: Color = Mesa.dust) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .rounded))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusColor: Color {
        switch miner.statusKind {
        case .idle: return Mesa.dust
        case .working: return Mesa.sky
        case .good: return Mesa.sage
        case .warning: return Mesa.wheat
        case .error: return Mesa.redRock
        }
    }

    private func formatUptime(_ s: Int) -> String {
        String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var miner: Miner?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { miner?.stopBlocking() }
    }
}

@main
struct OKMinerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var miner = Miner()

    var body: some Scene {
        WindowGroup("okminer") {
            ContentView()
                .environmentObject(miner)
                .onAppear { delegate.miner = miner }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
