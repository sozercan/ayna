//
//  ModelSetupPromptView.swift
//  ayna
//
//  Prompt view displayed when no AI models are configured.
//

import SwiftUI

struct ModelSetupPromptView: View {
    let issues: [String]

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Add a model to start chatting")
                    .font(.title3.weight(.semibold))
                Text(
                    "Head to Settings → Model to connect OpenAI, Azure, or AIKit models before sending your first message."
                )
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            }

            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }

            SettingsLink {
                Label("Open Settings", systemImage: "slider.horizontal.3")
            }
            .routeSettings(to: .models)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
