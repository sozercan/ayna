//
//  ApprovalRequestView.swift
//  ayna
//

import SwiftUI

/// View for displaying a pending tool execution approval request.
/// Shows tool name and arguments, with approve/deny actions.
struct ApprovalRequestView: View {
    let approval: PendingApproval
    let onApprove: (Bool) -> Void
    let onDeny: () -> Void
    let pendingCount: Int

    @State private var rememberForSession = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(Theme.statusConnecting)
                Text("Tool Approval Required")
                    .font(Typography.headline)
                Spacer()
                if pendingCount > 1 {
                    Text("\(pendingCount) pending")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: Spacing.xs) {
                Text("Tool:")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(approval.toolName)
                    .font(Typography.captionBold)
            }

            if !approval.arguments.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    ForEach(
                        Array(approval.arguments.sorted(by: { $0.key < $1.key })), id: \.key
                    ) { key, value in
                        HStack(alignment: .top, spacing: Spacing.xs) {
                            Text("\(key):")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Text(value)
                                .font(Typography.caption)
                                .lineLimit(3)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Toggle("Remember for session", isOn: $rememberForSession)
                    .font(Typography.caption)
                    .toggleStyle(.checkbox)

                Spacer()

                Button("Deny") {
                    onDeny()
                }
                .buttonStyle(.bordered)

                Button("Approve") {
                    onApprove(rememberForSession)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Theme.statusConnecting.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.CornerRadius.md)
                .stroke(Theme.statusConnecting.opacity(0.3), lineWidth: 1)
        )
    }
}
