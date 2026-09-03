import SwiftUI

struct ProcessRow: View {
    let process: ProcessSnapshot
    let actionability: ProcessActionability
    let alertReasons: [AlertReason]
    let isIgnored: Bool
    let actionOutcome: ProcessActionOutcome?
    let onSuspend: () -> Void
    let onResume: () -> Void
    let onTerminate: () -> Void
    let onForceQuit: () -> Void
    let onIgnore: () -> Void
    let onUndoIgnore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.13))
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(process.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    ForEach(Array(alertReasons.enumerated()), id: \.offset) { _, reason in
                        reasonBadge(reason)
                    }

                    if let worktree = process.worktreeState {
                        statusBadge(worktree.verdict.localizedDescription, color: worktreeColor(worktree.verdict))
                    }

                    if isIgnored {
                        statusBadge("무시 중", color: .secondary)
                    }
                }

                Text(metadata)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let statusDetail {
                    Text(statusDetail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(actionability.canAct ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(process.cpuPercent, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(cpuColor)
                    + Text("%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(cpuColor)

                Text(WatchdogFormatters.memory.string(fromByteCount: Int64(process.residentBytes)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(hasHighMemoryAlert ? Color.purple : Color.secondary)
            }
            .frame(width: 66, alignment: .trailing)

            Button(action: process.isSuspended ? onResume : onSuspend) {
                Image(systemName: process.isSuspended ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!actionability.canAct)
            .help(actionability.canAct ? (process.isSuspended ? "프로세스 재개" : "프로세스 일시 정지") : nonActionableReason)
            .accessibilityLabel(process.isSuspended ? "프로세스 재개" : "프로세스 일시 정지")
            .accessibilityHint(actionability.canAct ? "" : nonActionableReason)
            .accessibilityIdentifier(controlIdentifier(process.isSuspended ? "resume" : "suspend"))

            Group {
                if isIgnored {
                    Button(action: onUndoIgnore) {
                        Label("다시 감시", systemImage: "bell")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("다시 감시")
                    .accessibilityLabel("다시 감시")
                    .accessibilityIdentifier(controlIdentifier("undo-ignore"))
                } else {
                    Menu {
                        if actionability.canAct {
                            if process.isSuspended {
                                Button("재개", systemImage: "play.fill", action: onResume)
                            } else {
                                Button("일시 정지", systemImage: "pause.fill", action: onSuspend)
                            }

                            Button("종료할 때까지 무시", systemImage: "bell.slash", action: onIgnore)
                                .accessibilityIdentifier(controlIdentifier("ignore"))
                            Divider()
                            Button("종료…", systemImage: "xmark.circle", action: onTerminate)
                                .accessibilityIdentifier(controlIdentifier("terminate"))
                            Button("강제 종료…", systemImage: "bolt.trianglebadge.exclamationmark", role: .destructive, action: onForceQuit)
                                .accessibilityIdentifier(controlIdentifier("force-quit"))
                    }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(actionability.canAct ? .primary : .tertiary)
                            .frame(width: 22, height: 22)
                            .background(
                                Color.secondary.opacity(actionability.canAct ? 0.12 : 0.06),
                                in: Circle()
                            )
                            .accessibilityLabel("프로세스 작업")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(!actionability.canAct)
                    .help(actionability.canAct ? "프로세스 작업" : nonActionableReason)
                    .accessibilityHint(actionability.canAct ? "" : nonActionableReason)
                    .accessibilityIdentifier(controlIdentifier("actions"))
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(actionability.canAct ? "프로세스 제어를 사용할 수 있습니다" : nonActionableReason)
        .accessibilityIdentifier(controlIdentifier("row"))
    }

    @ViewBuilder
    private func reasonBadge(_ reason: AlertReason) -> some View {
        switch reason {
        case .sustainedCPU:
            statusBadge("CPU 높음", color: .red)
        case .sustainedMemory:
            statusBadge("메모리 높음", color: .purple)
        case .orphan:
            statusBadge("고아 의심", color: .orange)
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var metadata: String {
        let identity = process.projectName.map { "\($0) · #\(process.id)" } ?? "PID \(process.id)"
        let elapsedParts = process.elapsed.split(separator: ":")
        let compactElapsed = elapsedParts.count >= 3
            ? elapsedParts.dropLast().joined(separator: ":")
            : process.elapsed
        return "\(identity)  ·  \(compactElapsed)"
    }

    private var iconName: String {
        switch process.kind {
        case .agent: "terminal"
        case .browserRenderer: "globe"
        case .application: "macwindow"
        case .system: "gearshape.2"
        case .other: "waveform.path.ecg"
        }
    }

    private var iconColor: Color {
        if process.suspectedOrphan { return .orange }
        if hasHotAlert { return .red }
        if hasHighMemoryAlert { return .purple }
        switch process.kind {
        case .agent: return .indigo
        case .browserRenderer: return .blue
        case .application: return .mint
        case .system: return .secondary
        case .other: return .secondary
        }
    }

    private var cpuColor: Color {
        if process.cpuPercent >= 150 { return .red }
        if process.cpuPercent >= 80 { return .orange }
        return .primary
    }

    private var rowBackground: Color {
        if hasHotAlert { return .red.opacity(0.06) }
        if hasHighMemoryAlert { return .purple.opacity(0.07) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.55)
    }

    private func worktreeColor(_ verdict: WorktreeVerdict) -> Color {
        switch verdict {
        case .clean: return .green
        case .dirty: return .blue
        case .missing: return .secondary
        }
    }

    private var hasHotAlert: Bool {
        alertReasons.contains {
            if case .sustainedCPU = $0 { return true }
            return false
        }
    }

    private var hasHighMemoryAlert: Bool {
        alertReasons.contains {
            if case .sustainedMemory = $0 { return true }
            return false
        }
    }

    private var nonActionableReason: String {
        if isIgnored { return "무시를 취소해야 제어할 수 있습니다" }
        if actionability.isProtected { return "보호된 프로세스라 제어할 수 없습니다" }
        switch actionability.freshness {
        case .current: return "현재 제어할 수 없습니다"
        case .stale: return "관찰 정보가 오래되어 새로고침 후 제어할 수 있습니다"
        case .unavailable: return "관찰 정보가 없어 제어할 수 없습니다"
        }
    }

    private var statusDetail: String? {
        if let actionOutcome {
            return outcomeText(actionOutcome)
        }
        if !actionability.canAct {
            return nonActionableReason
        }
        return alertReasons.compactMap {
            if case let .orphan(reason) = $0 { return reason.localizedDescription }
            return nil
        }.first
    }

    private var accessibilityLabel: String {
        "\(process.displayName), PID \(process.id)"
    }

    private var accessibilityValue: String {
        var values = [
            "CPU \(Int(process.cpuPercent.rounded()))%",
            "메모리 \(WatchdogFormatters.memory.string(fromByteCount: Int64(process.residentBytes)))",
        ]
        values.append(contentsOf: alertReasons.map(\.text))
        if isIgnored { values.append("종료할 때까지 무시 중") }
        if let actionOutcome { values.append(outcomeText(actionOutcome)) }
        return values.joined(separator: ", ")
    }

    private func outcomeText(_ outcome: ProcessActionOutcome) -> String {
        switch outcome {
        case .signalDelivered: return "신호 전달됨 · 종료 여부는 확인되지 않음"
        case .awaitingExit: return "신호 전달됨 · 종료 확인 중"
        case .exited: return "종료 확인됨"
        case .stillRunning: return "신호 후에도 실행 중"
        case .identityChanged: return "PID가 다른 프로세스로 바뀜"
        case .verificationFailed: return "종료 여부를 확인하지 못함"
        case let .failed(message): return "작업 실패: \(message)"
        }
    }

    private func controlIdentifier(_ control: String) -> String {
        "process.\(process.id).\(process.startTimeMicroseconds).\(control)"
    }
}
