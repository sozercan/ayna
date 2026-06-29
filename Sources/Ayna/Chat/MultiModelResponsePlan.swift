//
//  MultiModelResponsePlan.swift
//  ayna
//
//  Plans the placeholder messages and response group for a multi-model turn.
//

import Foundation

/// Immutable setup for a multi-model response turn.
///
/// The plan keeps response-group construction and model-to-message identity in one
/// pure Module so UI callers do not have to mutate dictionaries that are later
/// captured by streaming callbacks.
struct MultiModelResponsePlan: Equatable, Sendable {
    let responseGroup: ResponseGroup
    let placeholderMessages: [Message]
    let messageIDsByModel: [String: UUID]

    var responseGroupId: UUID {
        responseGroup.id
    }

    init(
        models: [String],
        userMessageId: UUID,
        responseGroupId: UUID = UUID(),
        mediaType: Message.MediaType? = nil
    ) {
        var messageIDsByModel: [String: UUID] = [:]
        var entries: [ResponseGroup.ResponseEntry] = []
        var placeholderMessages: [Message] = []

        for model in models {
            let messageId = UUID()
            messageIDsByModel[model] = messageId
            entries.append(ResponseGroup.ResponseEntry(
                id: messageId,
                modelName: model,
                status: .streaming
            ))
            placeholderMessages.append(Message(
                id: messageId,
                role: .assistant,
                content: "",
                model: model,
                responseGroupId: responseGroupId,
                mediaType: mediaType
            ))
        }

        self.messageIDsByModel = messageIDsByModel
        self.placeholderMessages = placeholderMessages
        self.responseGroup = ResponseGroup(
            id: responseGroupId,
            userMessageId: userMessageId,
            responses: entries
        )
    }

    func messageId(for model: String) -> UUID? {
        messageIDsByModel[model]
    }
}
