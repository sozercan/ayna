//
//  WatchMessageComposer.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

    import SwiftUI

    /// Message composer for Watch with dictation and text input
    /// Supports voice dictation (primary) and scribble/keyboard (secondary)
    struct WatchMessageComposer: View {
        let onSend: (String) -> Void
        let onCancel: () -> Void

        @State private var messageText = ""
        @FocusState private var isTextFieldFocused: Bool

        var body: some View {
            NavigationStack {
                VStack(spacing: Spacing.md) {
                    // Text field with dictation
                    TextField("Message", text: $messageText)
                        .focused($isTextFieldFocused)
                        .textContentType(.none)
                        .submitLabel(.send)
                        .onSubmit {
                            sendMessage()
                        }

                    // Quick action buttons
                    HStack(spacing: Spacing.lg) {
                        // Cancel button
                        Button {
                            onCancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        // Send button
                        Button {
                            sendMessage()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(messageText.isEmpty ? Theme.textSecondary : Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(messageText.isEmpty)
                    }
                }
                .padding()
                .navigationTitle("New Message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            onCancel()
                        }
                    }
                }
            }
            .onAppear {
                // Auto-focus the text field to trigger dictation option
                isTextFieldFocused = true
            }
        }

        private func sendMessage() {
            let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            onSend(trimmed)
            messageText = ""
        }
    }

    /// Quick replies sheet with common responses
    struct WatchQuickRepliesView: View {
        let onSelect: (String) -> Void

        private let quickReplies = [
            "Yes",
            "No",
            "Thanks!",
            "Tell me more",
            "Can you explain?",
            "Summarize this"
        ]

        var body: some View {
            List {
                ForEach(quickReplies, id: \.self) { reply in
                    Button {
                        onSelect(reply)
                    } label: {
                        Text(reply)
                            .font(Typography.bodySecondary)
                    }
                }
            }
            .navigationTitle("Quick Replies")
        }
    }

    #if DEBUG
        struct WatchMessageComposer_Previews: PreviewProvider {
            static var previews: some View {
                WatchMessageComposer(
                    onSend: { _ in },
                    onCancel: {}
                )
            }
        }
    #endif

#endif
