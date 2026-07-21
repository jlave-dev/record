import ABSupport
import AVFoundation
import CoreMedia
import Foundation
import Speech

@main
struct AppleTranscribe {
    static func main() async {
        do {
            let options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
            guard #available(macOS 26.0, *) else {
                throw CLIError("Apple SpeechTranscriber requires macOS 26 or newer")
            }
            try await transcribe(options)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("\(error.message)\n".utf8))
            exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("apple transcription failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @available(macOS 26.0, *)
    private static func transcribe(_ options: CLIOptions) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw CLIError("Apple SpeechTranscriber is not available on this Mac")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: options.locale) else {
            throw CLIError("Apple SpeechTranscriber does not support locale \(options.locale.identifier)")
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: options.input)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let clock = ContinuousClock()
        let started = clock.now

        async let collected: [TranscriptSegment] = collectFinalSegments(from: transcriber)
        let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
        if let lastSampleTime {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let segments = try await collected
        let processingSeconds = seconds(started.duration(to: clock.now))
        let result = TranscriptResult(
            engine: "apple-speechtranscriber",
            model: "macOS managed SpeechTranscriber asset",
            locale: locale.identifier,
            inputFile: options.input.lastPathComponent,
            audioDurationSeconds: try audioDurationSeconds(options.input),
            processingSeconds: processingSeconds,
            transcript: normalizedTranscript(segments),
            segments: segments
        )
        try writeResult(result, to: options.output)
    }

    @available(macOS 26.0, *)
    private static func collectFinalSegments(from transcriber: SpeechTranscriber) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for try await result in transcriber.results where result.isFinal {
            let start = CMTimeGetSeconds(result.range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
            segments.append(TranscriptSegment(
                startMs: Int((start * 1000).rounded()),
                endMs: Int((end * 1000).rounded()),
                text: String(result.text.characters)
            ))
        }
        return segments
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
