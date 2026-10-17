#if !APPSTORE
import SwiftUI

// MARK: - The agent sessions that have stopped, and the box to continue them
//
// One row per project rather than per pill, because three `claude` in three
// projects share a single pill and the point here is to see all three. Each row
// takes the next instruction and sends it straight to that session through
// `AgentRunLauncher`; the hooks then follow the continued turn like any other,
// so approvals keep coming back to the notch to be answered by hand.

struct WaitingSessionsView: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool

    /// What has been typed, per session, so switching rows does not lose it.
    @State private var drafts: [String: String] = [:]
    @State private var bulkText: String = ""
    @State private var confirmingAll = false
    @State private var notice: String = ""

    private var sessions: [ResumableSession] { state.waitingSessions }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if state.scanningWaitingSessions && sessions.isEmpty {
                Text("Looking for sessions…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else if sessions.isEmpty {
                Text("Nothing is waiting. Sessions show up here once an agent stops.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sessions, id: \.sessionId) { session in
                            row(for: session)
                        }
                    }
                }
                .frame(maxHeight: 280)

                Divider().opacity(0.2)
                bulkSection
            }

            if !notice.isEmpty {
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        // A popover opens in a window of its own, which does not inherit the
        // island's appearance, so on a Mac set to light mode this panel came up
        // white against the black island. Same treatment the Flow window uses.
        .background(Color(hex: "#0E0F11"))
        .preferredColorScheme(.dark)
        .task {
            if sessions.isEmpty { state.refreshWaitingSessions() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Agents waiting")
                .font(.system(size: 12, weight: .semibold))
            if !sessions.isEmpty {
                Text("\(sessions.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            Spacer()
            Button {
                state.refreshWaitingSessions()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .disabled(state.scanningWaitingSessions)
        }
    }

    // MARK: One session

    @ViewBuilder
    private func row(for session: ResumableSession) -> some View {
        let busy = AgentRunLauncher.shared.isRunning(session.sessionId)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: session.agent == .codex ? "#2DD4BF" : "#D97757"))
                    .frame(width: 7, height: 7)
                Text(session.projectName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text(session.agent.displayName)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                Spacer()
                Text(Self.sinceLabel(session.lastActivity))
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                TextField(busy ? "Working…" : "What next?", text: Binding(
                    get: { drafts[session.sessionId] ?? "" },
                    set: { drafts[session.sessionId] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .disabled(busy)
                .onSubmit { send(to: session) }

                Button("Send") { send(to: session) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(busy || (drafts[session.sessionId] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text(session.cwd)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Everything at once

    private var bulkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Same instruction for every session above…", text: $bulkText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            HStack(spacing: 8) {
                if confirmingAll {
                    // Each one of these starts real work in a real repository,
                    // so the count and the folders are named before it fires.
                    Text("Send to \(targets.count) session(s) in \(folderList)?")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Cancel") { confirmingAll = false }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Send") { sendToAll() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Spacer()
                    Button("Send to all (\(targets.count))") { confirmingAll = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(bulkText.trimmingCharacters(in: .whitespaces).isEmpty || targets.isEmpty)
                }
            }
        }
    }

    /// What "all" means: everything listed that is not already working, capped.
    private var targets: [ResumableSession] {
        sessions
            .filter { !AgentRunLauncher.shared.isRunning($0.sessionId) }
            .prefix(AgentRunLauncher.maxConcurrent)
            .map { $0 }
    }

    private var folderList: String {
        let names = targets.prefix(3).map(\.projectName)
        let rest = targets.count - names.count
        return rest > 0 ? names.joined(separator: ", ") + " and \(rest) more" : names.joined(separator: ", ")
    }

    // MARK: Sending

    private func send(to session: ResumableSession) {
        let text = (drafts[session.sessionId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try AgentRunLauncher.shared.run(session: session, text: text)
            drafts[session.sessionId] = ""
            notice = "Sent to \(session.projectName)."
            state.refreshWaitingSessions()
        } catch let error as AgentRunError {
            notice = error.localizedDescription
        } catch {
            notice = error.localizedDescription
        }
    }

    private func sendToAll() {
        let text = bulkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let outcome = AgentRunLauncher.shared.runAll(sessions: targets, text: text)
        confirmingAll = false
        bulkText = ""
        if outcome.failed.isEmpty {
            notice = "Sent to \(outcome.started.count) session(s)."
        } else {
            notice = "Sent to \(outcome.started.count), \(outcome.failed.count) refused."
        }
        state.refreshWaitingSessions()
    }

    // MARK: Small helpers

    static func sinceLabel(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 90 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }
}
#endif
