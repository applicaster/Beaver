import SwiftUI

// MARK: - Wrapper badge

/// Small tag naming the *outermost* wrapper a value was stored in —
/// `json`, `base64` or `jwt`. What the user actually put on the device,
/// not what it eventually decoded to.
struct DecodeBadge: View {
    let kind: DecodeKind

    var body: some View {
        Text(kind.badgeText)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
            .foregroundStyle(.secondary)
            .help(kind.badgeHelp)
    }
}

// MARK: - Token verdict

/// Colour-coded answer to "is this token expired, and can I ignore it?"
/// — shown on the row so a stale token is visible without expanding.
struct JWTStatusChip: View {
    let status: JWTStatus

    /// True when the value merely *contains* the token rather than
    /// being one, which changes the tooltip.
    var isNested: Bool = false

    var body: some View {
        Text(status.chipText)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(status.tint.opacity(0.18)))
            .foregroundStyle(status.tint)
            .help(isNested
                  ? "Contains a token that is \(status.label)"
                  : "This token is \(status.label)")
    }
}

extension JWTStatus {
    /// Kept out of the decoder so that stays free of SwiftUI.
    var tint: Color {
        switch self {
        case .valid:   .green
        case .expired: .red
        case .pending: .orange
        }
    }
}

// MARK: - Claims summary

/// Expires / Issued / Issuer / Subject / Audience in plain words, so
/// "is this expired and who is it for?" is answerable without reading
/// the raw token.
struct JWTSummaryView: View {
    let status: JWTStatus?
    let claims: [JWTClaim]

    var body: some View {
        if status != nil || !claims.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let status {
                    JWTStatusChip(status: status)
                }
                ForEach(claims, id: \.label) { claim in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(claim.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 58, alignment: .leading)
                        Text(claim.value)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }
}

// MARK: - Formatted / Raw switch

/// The Formatted ↔ Raw switch, plus the plain-language note explaining
/// why the value could be decoded at all.
struct DecodeTabBar: View {
    @Binding var showingRaw: Bool

    /// Empty for a value that was already structured and needed no
    /// decoding — there is nothing to explain.
    var note: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $showingRaw) {
                Text("Formatted").tag(false)
                Text("Raw").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if !showingRaw, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Raw value block

/// The exact stored string, escaping and all, with its own copy action.
struct RawValueBlock: View {
    let text: String

    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                toasts.success("Copied raw value")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy the exact stored string")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
