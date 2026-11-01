import CoreGraphics
import Foundation
import ImageIO
import GlyphRecognition

/// Apple image decoding lives outside the pure Swift recognition target.
public enum ImageDecoder {
    public enum DecodeError: Error { case unreadableImage, incompleteImage, cannotCreateContext }

    public static func load(_ url: URL) throws -> LuminanceImage {
        try decode(Data(contentsOf: url))
    }

    /// The platform image behind some encoded data, for callers that need the
    /// colour regions as well as the luminance the recognizer consumes.
    public static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return image
    }

    public static func decode(_ data: Data) throws -> LuminanceImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DecodeError.unreadableImage
        }
        guard CGImageSourceGetStatus(source) == .statusComplete else { throw DecodeError.incompleteImage }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DecodeError.unreadableImage }
        let result = try decode(image)
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw DecodeError.incompleteImage }
        return result
    }

    /// Accepts upright pixels, as saved by Spike B. Apply capture/EXIF
    /// orientation first for other sources. Output row zero is the top row.
    /// Transparent pixels composite over black in the zero-filled gray context.
    public static func decode(_ image: CGImage) throws -> LuminanceImage {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw DecodeError.cannotCreateContext
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try LuminanceImage(width: width, height: height, pixels: pixels)
    }
}

extension ImageDecoder {
    /// Decodes a rectangle of an image as packed RGB.
    ///
    /// Separate from `decode(_:)` on purpose. The luminance path is what the
    /// recognition suite validates, down to the exact grey Core Graphics
    /// produces, so it is left untouched and colour is decoded only for the
    /// small regions that genuinely need it — the slot indicators and the
    /// app's own overlay marker.
    public static func decodeColor(_ image: CGImage, in rect: CGRect) throws -> ColorImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = rect.intersection(bounds).integral
        guard !crop.isEmpty, let cropped = image.cropping(to: crop) else {
            throw DecodeError.unreadableImage
        }
        let width = cropped.width, height = cropped.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw DecodeError.cannotCreateContext
            }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var packed = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            packed[pixel * 3] = rgba[pixel * 4]
            packed[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            packed[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return try ColorImage(width: width, height: height, pixels: packed)
    }

    /// The colour strip holding the header, the slot indicators and the input
    /// countdown, paired with the height of the frame it came from.
    public static func topBand(_ image: CGImage, layout: GameUILayout = GameUILayout()) throws -> FrameTopBand {
        let rows = Int((layout.topBandBottom * Double(image.height)).rounded(.up))
        let band = try decodeColor(image, in: CGRect(x: 0, y: 0, width: image.width, height: rows))
        return FrameTopBand(image: band, frameHeight: image.height)
    }
}
