import Foundation
import Photos

/// Adds finished recordings to the player's photo library. Add-only access:
/// the app never reads what is already there.
enum PhotoLibrarySaver {
    enum Failure: LocalizedError {
        case notAllowed

        var errorDescription: String? {
            String(localized: "Dynamic Glyph isn't allowed to add to Photos.",
                   comment: "Why a recording could not be saved to Photos.")
        }
    }

    /// Asks once; later calls return the player's answer without a prompt.
    static func requestAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
    }

    /// Moves the file into the library rather than copying it, so a long
    /// recording does not briefly need twice its size in free space.
    static func saveVideo(at url: URL) async throws {
        guard await requestAccess() else { throw Failure.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }
}
