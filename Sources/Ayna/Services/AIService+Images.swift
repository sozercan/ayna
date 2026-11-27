import Foundation

#if !os(watchOS)
    extension AIService {
        @discardableResult
        func generateImage(
            prompt: String,
            model: String? = nil,
            onComplete: @escaping @Sendable (Data) -> Void,
            onError: @escaping @Sendable (Error) -> Void,
            attempt: Int = 0
        ) -> AIImageRequest? {
            let requestModel = (model ?? selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestModel.isEmpty else {
                onError(AynaError.noModelSelected)
                return nil
            }

            let effectiveProvider: AIProvider
            do {
                effectiveProvider = try resolvedProvider(for: requestModel)
            } catch {
                onError(error)
                return nil
            }
            let endpointInfo = customEndpoint(for: requestModel)

            let requestConfig = OpenAIImageService.RequestConfig(
                model: requestModel,
                apiKey: getAPIKey(for: requestModel),
                provider: effectiveProvider,
                customEndpoint: endpointInfo?.endpoint,
                azureAPIVersion: azureAPIVersion
            )

            let imageConfig = OpenAIImageService.ImageConfig(
                size: imageSize,
                quality: imageQuality,
                outputFormat: outputFormat,
                outputCompression: outputCompression
            )

            let flightID = RequestFlightID()
            let requestHandle = OpenAIImageService.RequestHandle()
            imageRequests[flightID] = requestHandle

            imageService.generateImage(
                prompt: prompt,
                requestConfig: requestConfig,
                imageConfig: imageConfig,
                requestHandle: requestHandle,
                onComplete: { [weak self] data in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.finishImageRequest(flightID, handle: requestHandle)
                        else {
                            return
                        }
                        onComplete(data)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.finishImageRequest(flightID, handle: requestHandle)
                        else {
                            return
                        }
                        onError(error)
                    }
                },
                attempt: attempt
            )
            return AIImageRequest(service: self, flightID: flightID)
        }

        @discardableResult
        func requestImage(
            prompt: String,
            sourceImages: [OpenAIImageService.SourceImage],
            model: String,
            onComplete: @escaping @Sendable (Data) -> Void,
            onError: @escaping @Sendable (Error) -> Void
        ) -> AIImageRequest? {
            if sourceImages.isEmpty {
                return generateImage(prompt: prompt, model: model, onComplete: onComplete, onError: onError)
            }
            return editImage(
                prompt: prompt,
                sourceImages: sourceImages,
                model: model,
                onComplete: onComplete,
                onError: onError
            )
        }

        @discardableResult
        func editImage(
            prompt: String,
            sourceImages: [OpenAIImageService.SourceImage],
            model: String? = nil,
            onComplete: @escaping @Sendable (Data) -> Void,
            onError: @escaping @Sendable (Error) -> Void
        ) -> AIImageRequest? {
            let requestModel = (model ?? selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestModel.isEmpty else {
                onError(AynaError.noModelSelected)
                return nil
            }

            let effectiveProvider: AIProvider
            do {
                effectiveProvider = try resolvedProvider(for: requestModel)
            } catch {
                onError(error)
                return nil
            }
            let endpointInfo = customEndpoint(for: requestModel)

            let requestConfig = OpenAIImageService.RequestConfig(
                model: requestModel,
                apiKey: getAPIKey(for: requestModel),
                provider: effectiveProvider,
                customEndpoint: endpointInfo?.endpoint,
                azureAPIVersion: azureAPIVersion
            )

            let imageConfig = OpenAIImageService.ImageConfig(
                size: imageSize,
                quality: imageQuality,
                outputFormat: outputFormat,
                outputCompression: outputCompression
            )

            let flightID = RequestFlightID()
            let requestHandle = OpenAIImageService.RequestHandle()
            imageRequests[flightID] = requestHandle

            imageService.editImage(
                prompt: prompt,
                sourceImages: sourceImages,
                requestConfig: requestConfig,
                imageConfig: imageConfig,
                requestHandle: requestHandle,
                onComplete: { [weak self] data in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.finishImageRequest(flightID, handle: requestHandle)
                        else {
                            return
                        }
                        onComplete(data)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.finishImageRequest(flightID, handle: requestHandle)
                        else {
                            return
                        }
                        onError(error)
                    }
                }
            )
            return AIImageRequest(service: self, flightID: flightID)
        }

        func cancelImageRequest(_ flightID: RequestFlightID) {
            guard let requestHandle = imageRequests.removeValue(forKey: flightID) else { return }
            requestHandle.cancel()
        }

        private func finishImageRequest(
            _ flightID: RequestFlightID,
            handle: OpenAIImageService.RequestHandle
        ) -> Bool {
            guard imageRequests[flightID] === handle else { return false }
            imageRequests.removeValue(forKey: flightID)
            handle.finish()
            return true
        }
    }
#endif
