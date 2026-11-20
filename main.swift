import AppKit
import SwiftUI
import Foundation

// MARK: - Data

struct AgentRow: Decodable, Identifiable {
    let key: String
    let host: String
    let session: String
    let tab: String
    let block_id: String
    let pane: String?
    let title: String?
    let harness: String?
    let state: String
    let kind: String?
    let ask: String?
    let msg: String?
    let since: String?
    let since_estimated: Bool?
    let updated_at: String?
    let seen: Bool?
    let group: String?
    let stale: Bool?
    let suspect: Bool?

    var id: String { key }
    var isNeedsYou: Bool { group == "needs_you" }
    var isWorking: Bool { group == "working" }

    var cleanMessage: String {
        guard let msg, !msg.isEmpty else { return "" }
        return msg.components(separatedBy: .newlines).first ?? ""
    }

    var whereText: String {
        let tabGeneric = tab.hasPrefix("Window ")
        let blockLabel = (title?.isEmpty == false) ? title! : (pane ?? "")
        if !tab.isEmpty && !tabGeneric {
            var text = "\(session) › \(tab)"
            if let pane, !pane.isEmpty, pane != "shell", pane != tab {
                text += " › \(pane)"
            }
            return text
        }
        if !blockLabel.isEmpty { return "\(session) › \(blockLabel)" }
        return session
    }

    var hostSuffix: String? {
        host == "local" ? nil : "@\(host)"
    }

    var ageText: String {
        let raw = since ?? updated_at
        guard let date = DateParse.parse(raw) else { return "-" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let prefix = (since_estimated == true) ? "≥" : ""
        if seconds < 60 { return "\(prefix)\(seconds)s" }
        if seconds < 3600 { return "\(prefix)\(seconds / 60)m" }
        if seconds < 86400 { return "\(prefix)\(seconds / 3600)h" }
        return "\(prefix)\(seconds / 86400)d"
    }
}

enum DateParse {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

struct OverlayError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Model

final class BoardModel: ObservableObject {
    @Published var rows: [AgentRow] = []
    @Published var errorText: String?
    @Published var isRefreshing = false
    @Published var jumpingKey: String?
    @Published var toast: String?
    @Published var toastIsError = false
    @Published var showWorking = true
    @Published var clock = Date()

    var onLayoutChange: (() -> Void)?
    var onNeedsCountChange: ((Int) -> Void)?

    private let binary: String
    private let isDemo: Bool
    private let workQueue = DispatchQueue(label: "rexboard.overlay.client")
    private let parseQueue = DispatchQueue(label: "rexboard.overlay.stream")
    private var watchProcess: Process?
    private var watchOut: Pipe?
    private var watchErr: Pipe?
    private var streamBuffer = Data()
    private var streamGeneration = 0
    private var streamStderr = ""
    private var restartWork: DispatchWorkItem?
    private var restartDelay: TimeInterval = 1
    private var stopping = false
    private var clockTimer: Timer?
    private var toastWork: DispatchWorkItem?

    init() {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/rexboard",
            "/opt/homebrew/bin/rexboard",
            "/usr/local/bin/rexboard"
        ]
        binary = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
        isDemo = ProcessInfo.processInfo.environment["REXBOARD_OVERLAY_DEMO"] == "1"
        if isDemo { rows = BoardModel.demoRows() }
    }

    var needsRows: [AgentRow] { rows.filter { $0.isNeedsYou } }
    var workingRows: [AgentRow] { rows.filter { $0.isWorking } }
    var quietCount: Int { rows.filter { !$0.isNeedsYou && !$0.isWorking }.count }

    var workingShown: [AgentRow] {
        guard showWorking else { return [] }
        return Array(workingRows.prefix(3))
    }

    var workingOverflow: Int {
        guard showWorking else { return 0 }
        return max(0, workingRows.count - 3)
    }

    var preferredHeight: CGFloat {
        var height: CGFloat = 44 + 1
        if errorText != nil { height += 34 }
        if needsRows.isEmpty && workingRows.isEmpty {
            height += 64
        } else {
            if !needsRows.isEmpty {
                height += 22 + CGFloat(needsRows.count) * 50
            }
            if !workingRows.isEmpty {
                height += 22 + CGFloat(workingShown.count) * 50
                if workingOverflow > 0 { height += 18 }
            }
        }
        height += 26
        return min(max(height, 150), 620)
    }

    func start() {
        startClock()
        if isDemo {
            onNeedsCountChange?(rows.filter { $0.isNeedsYou }.count)
            onLayoutChange?()
            return
        }
        startWatch()
    }

    func stop() {
        stopping = true
        restartWork?.cancel()
        restartWork = nil
        clockTimer?.invalidate()
        clockTimer = nil
        closeWatch()
    }

    private func startClock() {
        clockTimer?.invalidate()
        let next = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.clock = Date()
        }
        RunLoop.main.add(next, forMode: .common)
        clockTimer = next
    }

    func setVisible(_ visible: Bool) {
        if visible && !isDemo {
            startWatch()
        }
    }

    func refreshNow() {
        if isDemo {
            return
        }
        restartWatch()
    }

    private func restartWatch() {
        guard !stopping else { return }
        restartWork?.cancel()
        restartWork = nil
        closeWatch()
        restartDelay = 1
        startWatch()
    }

    private func closeWatch() {
        streamGeneration += 1
        watchOut?.fileHandleForReading.readabilityHandler = nil
        watchErr?.fileHandleForReading.readabilityHandler = nil
        if let process = watchProcess {
            process.terminationHandler = nil
            process.terminate()
        }
        watchProcess = nil
        watchOut = nil
        watchErr = nil
        isRefreshing = false
    }

    private func startWatch() {
        guard !stopping, !isDemo, watchProcess == nil else { return }
        restartWork?.cancel()
        restartWork = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["watch", "--json"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment

        streamGeneration += 1
        let generation = streamGeneration
        parseQueue.async { [weak self] in
            self?.streamBuffer.removeAll(keepingCapacity: true)
        }
        streamStderr = ""
        isRefreshing = true

        let outHandle = stdout.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.streamGeneration == generation else { return }
                self.parseQueue.async {
                    self.consumeStreamData(data, generation: generation)
                }
            }
        }

        let errHandle = stderr.fileHandleForReading
        errHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self, self.streamGeneration == generation else { return }
                self.streamStderr += text
                if self.streamStderr.count > 4096 {
                    self.streamStderr = String(self.streamStderr.suffix(4096))
                }
            }
        }

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, !self.stopping, self.streamGeneration == generation else { return }
                self.watchProcess = nil
                self.watchOut = nil
                self.watchErr = nil
                self.isRefreshing = false
                let detail = self.streamStderr.trimmingCharacters(in: .whitespacesAndNewlines)
                self.errorText = detail.isEmpty
                    ? "rexboard watch stopped (exit \(finished.terminationStatus))"
                    : detail
                self.onLayoutChange?()
                self.scheduleRestart()
            }
        }

        watchProcess = process
        watchOut = stdout
        watchErr = stderr

        do {
            try process.run()
        } catch {
            watchProcess = nil
            watchOut = nil
            watchErr = nil
            isRefreshing = false
            errorText = "cannot run rexboard: \(error.localizedDescription)"
            onLayoutChange?()
            scheduleRestart()
        }
    }

    private func consumeStreamData(_ data: Data, generation: Int) {
        guard streamGeneration == generation else { return }
        streamBuffer.append(data)
        let newline = Data([0x0A])
        while let range = streamBuffer.range(of: newline) {
            let line = streamBuffer.subdata(in: streamBuffer.startIndex..<range.lowerBound)
            streamBuffer.removeSubrange(streamBuffer.startIndex...range.lowerBound)
            guard !line.isEmpty else { continue }
            decodeStreamLine(line, generation: generation)
        }
    }

    private func decodeStreamLine(_ line: Data, generation: Int) {
        do {
            let rows = try JSONDecoder().decode([AgentRow].self, from: line)
            DispatchQueue.main.async {
                guard self.streamGeneration == generation else { return }
                self.rows = rows
                self.errorText = nil
                self.isRefreshing = false
                self.restartDelay = 1
                self.onNeedsCountChange?(rows.filter { $0.isNeedsYou }.count)
                self.onLayoutChange?()
            }
        } catch {
            let text = String(data: line, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard self.streamGeneration == generation else { return }
                self.errorText = "cannot read rexboard stream: \(text.prefix(160))"
                self.onLayoutChange?()
            }
        }
    }

    private func scheduleRestart() {
        guard !stopping, watchProcess == nil else { return }
        restartWork?.cancel()
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 10)
        let work = DispatchWorkItem { [weak self] in
            self?.restartWork = nil
            self?.startWatch()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func jump(_ row: AgentRow) {
        guard jumpingKey == nil else { return }
        if isDemo {
            showToast("Demo row: \(row.whereText)", isError: false)
            return
        }
        jumpingKey = row.key
        toast = nil
        workQueue.async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.binary)
            process.arguments = ["jump", row.key]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.environment = ProcessInfo.processInfo.environment

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.jumpingKey = nil
                    self.showToast("cannot run rexboard", isError: true)
                }
                return
            }

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let success = process.terminationStatus == 0
            let text = String(data: success ? outData : errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            DispatchQueue.main.async {
                self.jumpingKey = nil
                if success {
                    self.showToast("Jumped to \(row.whereText)", isError: false)
                    self.activateRex()
                } else {
                    self.showToast(text?.isEmpty == false ? text! : "jump failed", isError: true)
                }
            }
        }
    }

    private func showToast(_ text: String, isError: Bool) {
        toast = text
        toastIsError = isError
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.toast = nil
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func activateRex() {
        let bundleID = "com.superlogical.rex"
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateAllWindows])
            }
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        }
    }

    func toggleWorking() {
        showWorking.toggle()
        onLayoutChange?()
    }

    private static func demoRows() -> [AgentRow] {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func stamp(_ secondsAgo: TimeInterval) -> String {
            formatter.string(from: now.addingTimeInterval(-secondsAgo))
        }

        func makeRow(
            key: String,
            host: String = "local",
            session: String,
            tab: String,
            title: String,
            harness: String,
            state: String,
            kind: String? = nil,
            msg: String,
            secondsAgo: TimeInterval,
            seen: Bool,
            group: String
        ) -> AgentRow {
            let time = stamp(secondsAgo)
            return AgentRow(
                key: key,
                host: host,
                session: session,
                tab: tab,
                block_id: key.components(separatedBy: "/").last ?? key,
                pane: "shell",
                title: title,
                harness: harness,
                state: state,
                kind: kind,
                ask: nil,
                msg: msg,
                since: time,
                since_estimated: false,
                updated_at: time,
                seen: seen,
                group: group,
                stale: false,
                suspect: false
            )
        }

        return [
            makeRow(
                key: "local/block:demo-api",
                session: "api-service",
                tab: "auth-refresh",
                title: "token refresh",
                harness: "claude-code",
                state: "blocked",
                kind: "permission",
                msg: "Allow npm test to run?",
                secondsAgo: 132,
                seen: false,
                group: "needs_you"
            ),
            makeRow(
                key: "local/block:demo-web",
                session: "web-app",
                tab: "checkout",
                title: "checkout flow",
                harness: "codex",
                state: "done",
                msg: "Tests pass. Ready for review.",
                secondsAgo: 96,
                seen: false,
                group: "needs_you"
            ),
            makeRow(
                key: "local/block:demo-docs",
                session: "docs-api",
                tab: "reference",
                title: "migration guide",
                harness: "claude-code",
                state: "working",
                msg: "Writing the migration guide",
                secondsAgo: 34,
                seen: true,
                group: "working"
            ),
            makeRow(
                key: "local/block:demo-worker",
                session: "worker",
                tab: "queue",
                title: "retry queue",
                harness: "codex",
                state: "working",
                msg: "Running integration tests",
                secondsAgo: 305,
                seen: true,
                group: "working"
            ),
            makeRow(
                key: "mini/block:demo-build",
                host: "mini",
                session: "build",
                tab: "ci",
                title: "nightly build",
                harness: "pi",
                state: "working",
                msg: "Compiling the release",
                secondsAgo: 47,
                seen: true,
                group: "working"
            ),
            makeRow(
                key: "local/block:demo-infra",
                session: "infra",
                tab: "terraform",
                title: "plan review",
                harness: "claude-code",
                state: "idle",
                msg: "Waiting for input",
                secondsAgo: 7200,
                seen: true,
                group: "quiet"
            ),
            makeRow(
                key: "local/block:demo-notes",
                session: "notes",
                tab: "release",
                title: "release notes",
                harness: "codex",
                state: "done",
                msg: "Changelog updated",
                secondsAgo: 5400,
                seen: true,
                group: "quiet"
            )
        ]
    }
}

// MARK: - Views

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class DragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(0.14) : Color.clear)
            )
    }
}

struct AgentRowView: View {
    let row: AgentRow
    let isJumping: Bool
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                stateIcon
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.whereText)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let host = row.hostSuffix {
                            Text(host)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        if isJumping {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(row.ageText)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !row.cleanMessage.isEmpty {
                        Text(row.cleanMessage)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Jump to \(row.whereText)")
    }

    @ViewBuilder private var stateIcon: some View {
        switch row.state {
        case "blocked":
            Image(systemName: row.kind == "question" ? "questionmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(Color.red)
        case "error":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.red)
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(row.seen == true ? Color.secondary : Color.green)
        case "working":
            ProgressView()
                .controlSize(.small)
                .tint(.orange)
        default:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: BoardModel
    let hide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            if let error = model.errorText {
                errorBanner(error)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    if !model.needsRows.isEmpty {
                        sectionHeader("NEEDS YOU", count: model.needsRows.count, color: .red)
                        ForEach(model.needsRows) { row in
                            rowView(row)
                        }
                    }
                    if !model.workingRows.isEmpty {
                        workingHeader
                        ForEach(model.workingShown) { row in
                            rowView(row)
                        }
                        if model.workingOverflow > 0 {
                            Text("+\(model.workingOverflow) more working")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 24)
                        }
                    }
                    if model.needsRows.isEmpty && model.workingRows.isEmpty {
                        allClear
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            footer
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VisualEffectView(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var subtitle: String {
        if model.errorText != nil { return "rexboard unavailable" }
        let needs = model.needsRows.count
        let working = model.workingRows.count
        if needs == 0 && working == 0 { return "all clear" }
        return "\(needs) need you · \(working) working"
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                WindowDragArea()
            }
            .frame(width: 12, height: 18)
            .help("Drag to move")

            Circle()
                .fill(model.errorText == nil ? Color.green : Color.red)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text("rexboard overlay")
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            }

            Button(action: { model.refreshNow() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh now")

            Button(action: hide) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .help("Hide overlay (menu bar icon restores)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(color.opacity(0.75))
            Spacer()
        }
        .padding(.top, 2)
    }

    private var workingHeader: some View {
        Button(action: { model.toggleWorking() }) {
            HStack(spacing: 6) {
                Image(systemName: model.showWorking ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                Text("WORKING")
                    .font(.system(size: 9, weight: .bold))
                Text("\(model.workingRows.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                Spacer()
            }
            .foregroundStyle(Color.orange.opacity(0.9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func rowView(_ row: AgentRow) -> some View {
        AgentRowView(row: row, isJumping: model.jumpingKey == row.key) {
            model.jump(row)
        }
    }

    private var allClear: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("All clear")
                    .font(.system(size: 12, weight: .medium))
                Text("No agent needs you")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(Color.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.10))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(model.toastIsError ? Color.red : Color.secondary)
                    .lineLimit(1)
            } else {
                Text(model.quietCount > 0 ? "\(model.quietCount) quiet" : "click a row to jump")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.08))
        }
    }
}

// MARK: - App

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private var model: BoardModel!
    private var statusItem: NSStatusItem!
    private var showItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var isVisible = true
    private let panelWidth: CGFloat = 380
    private let defaults = UserDefaults.standard
    private var resizeGuard = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = BoardModel()
        model.onLayoutChange = { [weak self] in self?.resizePanelToFit() }
        model.onNeedsCountChange = { [weak self] count in self?.updateStatusTitle(count: count) }

        setupStatusItem()
        setupPanel()
        model.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification,
            object: panel
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Rexboard")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        }

        let menu = NSMenu()
        showItem = NSMenuItem(title: "Hide Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Rex", action: #selector(openRex), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func setupPanel() {
        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: 260)
        panel = OverlayPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let root = ContentView(model: model) { [weak self] in
            self?.hideOverlay()
        }
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        restorePosition()
        panel.orderFrontRegardless()
    }

    private func preferredHeight() -> CGFloat {
        model.preferredHeight
    }

    private func restorePosition() {
        let height = preferredHeight()
        var frame = NSRect(x: 0, y: 0, width: panelWidth, height: height)
        let savedX = defaults.object(forKey: "panelX") as? Double
        let savedTop = defaults.object(forKey: "panelTop") as? Double

        if let savedX, let savedTop {
            frame.origin = NSPoint(x: savedX, y: savedTop - height)
        } else if let visible = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(
                x: visible.maxX - panelWidth - 16,
                y: visible.maxY - height - 12
            )
        } else {
            frame.origin = NSPoint(x: 80, y: 80)
        }

        panel.setFrame(clamp(frame), display: false)
        savePosition()
    }

    private func clamp(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var result = frame
        result.size.width = min(result.size.width, visible.width)
        result.size.height = min(result.size.height, visible.height)
        result.origin.x = min(max(result.origin.x, visible.minX + 8), visible.maxX - result.width - 8)
        result.origin.y = min(max(result.origin.y, visible.minY + 8), visible.maxY - result.height - 8)
        return result
    }

    private func savePosition() {
        guard let panel else { return }
        defaults.set(panel.frame.origin.x, forKey: "panelX")
        defaults.set(panel.frame.maxY, forKey: "panelTop")
    }

    private func resizePanelToFit() {
        guard let panel, !resizeGuard else { return }
        let newHeight = preferredHeight()
        let frame = panel.frame
        guard abs(frame.height - newHeight) > 0.5 else { return }

        resizeGuard = true
        let top = frame.maxY
        var next = NSRect(x: frame.origin.x, y: top - newHeight, width: panelWidth, height: newHeight)
        next = clamp(next)
        panel.setFrame(next, display: true)
        savePosition()
        resizeGuard = false
    }

    private func updateStatusTitle(count: Int) {
        statusItem.button?.title = count > 0 ? " \(count)" : ""
    }

    private func showOverlay() {
        isVisible = true
        showItem.title = "Hide Overlay"
        panel.orderFrontRegardless()
        model.setVisible(true)
        resizePanelToFit()
    }

    private func hideOverlay() {
        isVisible = false
        showItem.title = "Show Overlay"
        panel.orderOut(nil)
        model.setVisible(false)
    }

    @objc private func toggleOverlay() {
        if isVisible { hideOverlay() } else { showOverlay() }
    }

    @objc private func refreshNow() {
        model.refreshNow()
    }

    @objc private func panelMoved() {
        guard !resizeGuard else { return }
        savePosition()
    }

    @objc private func screenParametersChanged() {
        guard let panel else { return }
        panel.setFrame(clamp(panel.frame), display: true)
        savePosition()
        panel.orderFrontRegardless()
    }

    @objc private func didWake() {
        model.refreshNow()
    }

    @objc private func toggleLogin() {
        let fileManager = FileManager.default
        let path = loginPlistPath

        if isLoginEnabled() {
            try? fileManager.removeItem(atPath: path)
        } else {
            let directory = (path as NSString).deletingLastPathComponent
            try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)

            let executable = Bundle.main.executablePath
                ?? "\(NSHomeDirectory())/Applications/Rexboard Overlay.app/Contents/MacOS/RexboardOverlay"
            let logPath = "\(NSHomeDirectory())/Library/Logs/RexboardOverlay.log"
            let plist: [String: Any] = [
                "Label": "com.local.rexboard-overlay",
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "StandardOutPath": logPath,
                "StandardErrorPath": logPath
            ]
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            ) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }

        loginItem.state = isLoginEnabled() ? .on : .off
    }

    private var loginPlistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/com.local.rexboard-overlay.plist"
    }

    private func isLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: loginPlistPath)
    }

    @objc private func openRex() {
        let bundleID = "com.superlogical.rex"
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateAllWindows])
            }
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "rexboard-overlay" {
            switch url.host ?? url.path {
            case "toggle": toggleOverlay()
            case "show": showOverlay()
            case "hide": hideOverlay()
            case "refresh": model.refreshNow()
            default: showOverlay()
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
