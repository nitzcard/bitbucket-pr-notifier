import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a recording into an animated GIF, which GitHub shows inline in a job
/// summary (it can't play video there). A few frames a second at a small size
/// keeps the file light enough to load quickly.
enum GIF {
    static func make(from video: URL, fps: Double = 4, width: CGFloat = 800) -> URL? {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width)
        // screencapture only writes a frame when the screen changes: take the
        // latest frame at or before each moment.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .zero

        let duration = blocking { try? await asset.load(.duration).seconds } ?? 0
        guard duration > 0 else { return nil }
        let times = stride(from: 0, to: duration, by: 1 / fps).map { CMTime(seconds: $0, preferredTimescale: 600) }
        let frames: [CGImage] = blocking {
            var frames: [CGImage] = []
            for await result in generator.images(for: times) {
                if let image = try? result.image { frames.append(image) }
            }
            return frames
        }
        guard !frames.isEmpty else { return nil }

        let gif = video.deletingPathExtension().appendingPathExtension("gif")
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString,
                                                                frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(destination, frame, frameProperties) }
        return CGImageDestinationFinalize(destination) ? gif : nil
    }

    /// Runs async AVFoundation work from the tests' synchronous code.
    private static func blocking<T>(_ work: @escaping () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var result: T?
        Task.detached {
            result = await work()
            done.signal()
        }
        done.wait()
        return result!
    }
}
