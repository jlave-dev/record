import ABSupport
import AVFoundation
import FluidAudio
import Foundation

@main
struct FluidTranscribe {
    static func main() async {
        do {
            let options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
            try await transcribe(options)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("\(error.message)\n".utf8))
            exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("FluidAudio transcription failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func transcribe(_ options: CLIOptions) async throws {
        guard options.locale.language.languageCode?.identifier == "en" else {
            throw CLIError("FluidAudio Parakeet EOU currently supports English; use --locale en-US")
        }

        let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
        try await manager.loadModels()
        let audioFile = try AVAudioFile(forReading: options.input)
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            throw CLIError("could not allocate audio buffer")
        }
        try audioFile.read(into: buffer)

        let clock = ContinuousClock()
        let started = clock.now
        await manager.reset()
        var transcript = try await manager.process(audioBuffer: buffer)
        transcript += try await manager.finish()
        let processingSeconds = seconds(started.duration(to: clock.now))
        let eouTimestamps = await manager.getEouTimestampsMs()

        let result = TranscriptResult(
            engine: "fluidaudio-parakeet-eou",
            model: "FluidAudio 0.15.5 / Parakeet EOU 120M 320ms",
            locale: options.locale.identifier,
            inputFile: options.input.lastPathComponent,
            audioDurationSeconds: try audioDurationSeconds(options.input),
            processingSeconds: processingSeconds,
            transcript: transcript.split(whereSeparator: \Character.isWhitespace).joined(separator: " "),
            segments: [],
            endOfUtteranceTimestampsMs: eouTimestamps
        )
        try writeResult(result, to: options.output)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
