// ThumbnailCache.swift
// Fantasia
// Two-layer cache for video thumbnails and generated images, keyed by generation ID.
// Layer 1: NSCache (in-memory, evicted under memory pressure, clears on app kill)
// Layer 2: Caches directory on disk (persists across app launches, OS clears when low on storage)

import UIKit

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, UIImage>()
    private let diskURL: URL

    private init() {
        memory.countLimit = 150
        memory.totalCostLimit = 120 * 1024 * 1024  // 120 MB

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskURL = caches.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
    }

    subscript(id: String) -> UIImage? {
        get {
            // Layer 1: memory only — synchronous, fast. Callers that also want the disk layer
            // on a cache miss should use the async image(for:) below instead of this getter,
            // to avoid a blocking disk read on whatever thread calls this synchronously.
            memory.object(forKey: id as NSString)
        }
        set {
            guard let image = newValue else { return }
            store(image, key: id, toDisk: true)
        }
    }

    /// Full memory+disk lookup. Perf: the old subscript getter did the disk Data(contentsOf:)
    /// read synchronously, and callers (LibraryThumbnailView, GenerationCardView) invoked it
    /// directly from onAppear — a MainActor context — meaning a cold in-memory cache miss did a
    /// blocking disk read on the main thread. The disk read here runs on a detached background
    /// task so awaiting callers never block their own thread on it.
    func image(for id: String) async -> UIImage? {
        if let cached = memory.object(forKey: id as NSString) { return cached }
        let diskURL = self.diskURL
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            let file = diskURL.appendingPathComponent(id + ".jpg")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return UIImage(data: data)
        }.value
        if let loaded {
            store(loaded, key: id, toDisk: false) // warm memory cache from disk
        }
        return loaded
    }

    private func store(_ image: UIImage, key: String, toDisk: Bool) {
        let cost = Int(image.size.width * image.size.height * 4)
        memory.setObject(image, forKey: key as NSString, cost: cost)
        if toDisk {
            let file = diskURL.appendingPathComponent(key + ".jpg")
            if let data = image.jpegData(compressionQuality: 0.82) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}
