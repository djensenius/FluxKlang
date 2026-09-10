import AVFoundation
import Foundation
import Observation
import Speech

enum AssistantVoicePermissionState: Equatable, Sendable {
    case undetermined
    case denied
    case restricted
    case granted
    case unavailable
}

enum AssistantVoiceState: Equatable, Sendable {
    case idle
    case requestingPermission
    case preparingModel
    case listening
    case finalizing
    case failed(String)
}

struct AssistantTranscriptUpdate: Sendable {
    var text: String
    var isFinal: Bool
}

protocol AssistantSpeechTranscribing: Sendable {
    func permissionState() async -> AssistantVoicePermissionState
    func requestPermission() async -> AssistantVoicePermissionState
    func start() async throws -> AsyncThrowingStream<AssistantTranscriptUpdate, any Error>
    func finish() async
    func cancel() async
}

actor SpeechAnalyzerAssistantTranscriber: AssistantSpeechTranscribing {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    func permissionState() -> AssistantVoicePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .undetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .granted
        @unknown default: .unavailable
        }
    }

    func requestPermission() async -> AssistantVoicePermissionState {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return .denied }
        return .granted
    }

    func start() async throws -> AsyncThrowingStream<AssistantTranscriptUpdate, any Error> {
        let transcriber = try await preparedTranscriber()
        return try await start(transcriber: transcriber)
    }

    private func preparedTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        else {
            throw AssistantSpeechError.transcriberUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            break
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        case .unsupported:
            throw AssistantSpeechError.transcriberUnavailable
        @unknown default:
            throw AssistantSpeechError.transcriberUnavailable
        }
        return transcriber
    }

    private func start(
        transcriber: SpeechTranscriber
    ) async throws -> AsyncThrowingStream<AssistantTranscriptUpdate, any Error> {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let naturalFormat = inputNode.inputFormat(forBus: 0)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: naturalFormat
        ) else {
            throw AssistantSpeechError.noCompatibleAudioFormat
        }
        let speechAnalyzer = SpeechAnalyzer(modules: [transcriber])
        try await speechAnalyzer.prepareToAnalyze(in: format)

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        engine = audioEngine
        analyzer = speechAnalyzer

        let (updates, updatesContinuation) =
            AsyncThrowingStream<AssistantTranscriptUpdate, any Error>.makeStream()
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        audioEngine.prepare()
        try audioEngine.start()

        analysisTask = Task {
            do {
                _ = try await speechAnalyzer.analyzeSequence(inputStream)
            } catch is CancellationError {
                return
            } catch {
                updatesContinuation.finish(throwing: error)
            }
        }
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    updatesContinuation.yield(AssistantTranscriptUpdate(
                        text: String(result.text.characters),
                        isFinal: result.isFinal
                    ))
                }
                updatesContinuation.finish()
            } catch {
                updatesContinuation.finish(throwing: error)
            }
        }
        updatesContinuation.onTermination = { _ in
            Task { await self.cancel() }
        }
        return updates
    }

    func finish() async {
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await analysisTask?.result
        _ = await resultTask?.result
        clearReferences()
    }

    func cancel() async {
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        analysisTask?.cancel()
        resultTask?.cancel()
        _ = await analysisTask?.result
        _ = await resultTask?.result
        clearReferences()
    }

    private func stopAudio() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
    }

    private func clearReferences() {
        analysisTask = nil
        resultTask = nil
        engine = nil
        analyzer = nil
    }
}

enum AssistantSpeechError: LocalizedError {
    case transcriberUnavailable
    case noCompatibleAudioFormat

    var errorDescription: String? {
        switch self {
        case .transcriberUnavailable:
            "On-device transcription is unavailable for the current language."
        case .noCompatibleAudioFormat:
            "No compatible microphone format is available."
        }
    }
}

@MainActor
@Observable
final class AssistantVoiceController {
    private let transcriber: any AssistantSpeechTranscribing
    private var transcriptTask: Task<Void, Never>?

    private(set) var permission: AssistantVoicePermissionState = .undetermined
    private(set) var state: AssistantVoiceState = .idle
    private(set) var transcript = ""
    private(set) var isFinal = false

    init(transcriber: any AssistantSpeechTranscribing = SpeechAnalyzerAssistantTranscriber()) {
        self.transcriber = transcriber
    }

    func refreshPermission() async {
        permission = await transcriber.permissionState()
    }

    func start() {
        guard state != .listening else { return }
        transcript = ""
        isFinal = false
        transcriptTask = Task {
            permission = await transcriber.permissionState()
            if permission == .undetermined {
                state = .requestingPermission
                permission = await transcriber.requestPermission()
            }
            guard permission == .granted else {
                state = .failed("Microphone permission is required for push-to-talk.")
                return
            }
            state = .preparingModel
            do {
                let updates = try await transcriber.start()
                state = .listening
                for try await update in updates {
                    try Task.checkCancellation()
                    transcript = update.text
                    isFinal = update.isFinal
                }
                if state == .listening {
                    state = .idle
                }
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func finish() {
        guard state == .listening else { return }
        state = .finalizing
        Task {
            await transcriber.finish()
            isFinal = true
            state = .idle
        }
    }

    func cancel() {
        transcriptTask?.cancel()
        transcriptTask = nil
        Task { await transcriber.cancel() }
        transcript = ""
        isFinal = false
        state = .idle
    }
}
