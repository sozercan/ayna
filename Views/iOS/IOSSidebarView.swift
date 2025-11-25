//
//  IOSSidebarView.swift
//  ayna
//
//  Created on 11/22/25.
//

import SwiftUI

struct IOSSidebarView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var isEditing = false
    @State private var selectedConversations = Set<UUID>()

    var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return conversationManager.conversations
        }
        return conversationManager.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            List(selection: $conversationManager.selectedConversationId) {
                ForEach(filteredConversations) { conversation in
                    HStack {
                        if isEditing {
                            Image(systemName: selectedConversations.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedConversations.contains(conversation.id) ? .blue : .gray)
                                .font(.system(size: 22))
                                .onTapGesture {
                                    toggleSelection(for: conversation)
                                }
                        }

                        if isEditing {
                            ConversationRow(conversation: conversation)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    toggleSelection(for: conversation)
                                }
                        } else {
                            NavigationLink(value: conversation.id) {
                                ConversationRow(conversation: conversation)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            conversationManager.deleteConversation(conversation)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 80)
            }

            // Bottom Bar
            if isEditing {
                HStack {
                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Text("Delete")
                            .font(.headline)
                            .foregroundStyle(selectedConversations.isEmpty ? .gray : .red)
                    }
                    .disabled(selectedConversations.isEmpty)

                    Spacer()
                }
                .padding()
                .background(Color(uiColor: .systemBackground))
            } else {
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.gray)
                        TextField("Search", text: $searchText)
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.gray)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                    }

                    Button(action: {
                        conversationManager.selectedConversationId = ConversationManager.newConversationId
                    }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background {
                                Circle()
                                    .fill(.ultraThinMaterial)
                            }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation {
                        isEditing.toggle()
                        if !isEditing {
                            selectedConversations.removeAll()
                        }
                    }
                }
                .font(.system(size: 17))
                .foregroundStyle(.white)
            }

            ToolbarItem(placement: .topBarTrailing) {
                if !isEditing {
                    Button(action: {
                        showSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                IOSSettingsView()
            }
        }
    }

    private func toggleSelection(for conversation: Conversation) {
        if selectedConversations.contains(conversation.id) {
            selectedConversations.remove(conversation.id)
        } else {
            selectedConversations.insert(conversation.id)
        }
    }

    private func deleteSelected() {
        for id in selectedConversations {
            if let conversation = conversationManager.conversations.first(where: { $0.id == id }) {
                conversationManager.deleteConversation(conversation)
            }
        }
        withAnimation {
            isEditing = false
            selectedConversations.removeAll()
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var lastMessagePreview: String {
        conversation.messages.last?.content ?? "No messages"
    }

    var timeString: String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(conversation.updatedAt) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: conversation.updatedAt)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            if let image = UIImage(named: "AppIcon") {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.gradient)
                    .frame(width: 48, height: 48)
                    .overlay {
                        if let firstChar = conversation.title.first {
                            Text(String(firstChar))
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.white)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(timeString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(lastMessagePreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
