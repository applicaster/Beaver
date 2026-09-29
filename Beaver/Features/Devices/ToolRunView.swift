//
//  ToolRunView.swift
//  Beaver
//
//  D91: Run… on a tool row — the argument form from the tool's
//  inputSchema, Run (confirmed for risky names), and the result.

import SwiftUI

/// A run waiting for the person's confirmation.
struct PendingToolRun: Identifiable {
    let id = UUID()
    let name: String
    let arguments: [String: JSON]
    /// The history row it repeats, if any.
    var row: UUID? = nil
}

extension View {
    /// Asks before `pending` runs: "Run app.restart on Alpha?".
    func confirmToolRun(_ pending: Binding<PendingToolRun?>, app: String,
                        run: @escaping (PendingToolRun) -> Void) -> some View {
        confirmationDialog(
            pending.wrappedValue.map { "Run \($0.name) on \(app)?" } ?? "",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { item in
            Button("Run", role: .destructive) { run(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This tool may change the app's data, sign out or restart the app.")
        }
    }
}

struct ToolRunView: View {
    let session: Session
    let tool: DeviceTool
    let app: String
    @Environment(AppEnvironment.self) private var env
    @State private var values: [String: String] = [:]
    @State private var formError: ToolFormError?
    @State private var running = false
    @State private var outcome: Result<DeviceToolCall.Reply, DeviceToolCall.Failure>?
    @State private var pending: PendingToolRun?

    private var fields: [ToolFormField] { ToolForm.fields(tool) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.name).font(.system(.headline, design: .monospaced)).textSelection(.enabled)
                if !tool.description.isEmpty {
                    Text(tool.description).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !fields.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(fields) { field($0) }
                }
            }
            if let formError {
                Text(formError.message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the app…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
            if let outcome {
                Divider()
                ToolRunResultView(outcome: outcome)
            }
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .confirmToolRun($pending, app: app) { run($0.arguments) }
    }

    @ViewBuilder
    private func field(_ f: ToolFormField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(f.name).font(.system(.caption, design: .monospaced).weight(.semibold))
                if f.required {
                    Text("*").font(.caption.weight(.bold)).foregroundStyle(.red).help("Required")
                        .accessibilityLabel("required")
                }
            }
            switch f.kind {
            case .text, .number, .integer:
                TextField(f.placeholder, text: text(f.name)).textFieldStyle(.roundedBorder)
            case .json:
                TextField(f.placeholder, text: text(f.name), axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
            case .boolean:
                Toggle(f.name, isOn: flag(f)).toggleStyle(.checkbox).labelsHidden()
            case .choice(let options):
                Picker(f.name, selection: text(f.name)) {
                    Text(f.defaultValue.map { "Default (\($0.string ?? $0.text))" } ?? (f.required ? "Choose…" : "—"))
                        .tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if !f.help.isEmpty {
                Text(f.help).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(f.help)
    }

    private func text(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func flag(_ f: ToolFormField) -> Binding<Bool> {
        Binding(get: { values[f.name].map { $0 == "true" } ?? f.defaultValue?.bool ?? false },
                set: { values[f.name] = $0 ? "true" : "false" })
    }

    private func submit() {
        do {
            let arguments = try ToolForm.arguments(values, fields)
            formError = nil
            if DeviceToolCall.needsConfirmation(tool.name) {
                pending = PendingToolRun(name: tool.name, arguments: arguments)
            } else {
                run(arguments)
            }
        } catch {
            formError = error
        }
    }

    /// Not tied to the popover: closed early, the run still finishes, is
    /// logged and lands in the history.
    private func run(_ arguments: [String: JSON]) {
        running = true
        outcome = nil
        Task {
            outcome = await env.runDeviceTool(tool.name, arguments: arguments, sessionId: session.id)
            running = false
        }
    }
}

/// OK with the answer as a JSON tree (or its text) and Copy; or the reason
/// it failed.
struct ToolRunResultView: View {
    let outcome: Result<DeviceToolCall.Reply, DeviceToolCall.Failure>
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        switch outcome {
        case .success(let reply):
            let value = reply.value
            let copyText = value.string ?? value.prettyText
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("OK", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption.weight(.semibold))
                    Spacer()
                    Button { toasts.copy(copyText, "Copied result") } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(copyText.isEmpty)
                }
                ScrollView {
                    Group {
                        if value.string == nil, let tree = StorageRecord.parse(value.text, rootKey: "result") {
                            JSONTreeView(record: tree, expandsRoot: true)
                        } else {
                            Text(copyText.isEmpty ? "Done (no text)" : copyText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(copyText.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                if !reply.otherTypes.isEmpty {
                    Text("+\(reply.otherTypes.count) non-text item(s): \(reply.otherTypes.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .failure(let failure):
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
