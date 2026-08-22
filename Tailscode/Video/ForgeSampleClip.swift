#if DEBUG
    import AVFoundation
    import UIKit

    /// A few seconds of video written by this device, so the one state that needs a file on another
    /// machine — a finished clip playing in the stage — can be photographed on a simulator with no
    /// renderer on the tailnet. It is only ever reached from a staged board.
    enum ForgeSampleClip {
        private static let size = CGSize(width: 640, height: 352)
        private static let rate: Int32 = 24
        private static let seconds = 3

        static func make() async -> URL? {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("forge-sample.mp4")
            try? FileManager.default.removeItem(at: url)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(size.width),
                    AVVideoHeightKey: Int(size.height),
                ])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)
                ])
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            let frames = Int(rate) * seconds
            for frame in 0..<frames {
                while !input.isReadyForMoreMediaData {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard let buffer = paint(frame: frame, of: frames, pool: adaptor.pixelBufferPool)
                else { continue }
                adaptor.append(
                    buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: rate))
            }
            input.markAsFinished()
            await writer.finishWriting()
            return writer.status == .completed ? url : nil
        }

        /// One frame: a slow sweep of warm light across a dark field, which is enough to read as a
        /// moving picture in a still screenshot and in a loop.
        private static func paint(frame: Int, of frames: Int, pool: CVPixelBufferPool?)
            -> CVPixelBuffer?
        {
            guard let pool else { return nil }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                let buffer
            else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard
                let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer),
                    width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            else { return nil }
            let phase = CGFloat(frame) / CGFloat(max(frames - 1, 1))
            context.setFillColor(UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            let colors =
                [
                    UIColor(red: 1.0, green: 0.72, blue: 0.36, alpha: 1).cgColor,
                    UIColor(red: 0.42, green: 0.24, blue: 0.62, alpha: 0.9).cgColor,
                    UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 0).cgColor,
                ] as CFArray
            guard
                let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                    locations: [0, 0.45, 1])
            else { return nil }
            let centre = CGPoint(
                x: size.width * (0.2 + 0.6 * phase),
                y: size.height * (0.35 + 0.25 * sin(phase * .pi * 2)))
            context.drawRadialGradient(
                gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                endRadius: size.height * 0.9, options: [])
            return buffer
        }
    }
#endif
