//
//  TextRgba.swift
//  texture_rgba_renderer
//
//  Created by kingtous on 2023/2/17.
//

import Foundation
import FlutterMacOS
import CoreVideo

/// Rust's video thread pushes frames through a raw TextRgba pointer with no
/// lifetime contract. The registry retains live objects and is the only way
/// the C entry points resolve a pointer, so a concurrent close can never
/// leave Rust dereferencing a deallocated object.
@objc public class TextureRgbaRegistry: NSObject {
    private static let lock = NSLock()
    private static var live: [UInt: TextRgba] = [:]

    static func add(_ texture: TextRgba) {
        let ptr = UInt(bitPattern: Unmanaged.passUnretained(texture).toOpaque())
        lock.lock()
        live[ptr] = texture
        lock.unlock()
    }

    static func remove(_ texture: TextRgba) {
        let ptr = UInt(bitPattern: Unmanaged.passUnretained(texture).toOpaque())
        lock.lock()
        live.removeValue(forKey: ptr)
        lock.unlock()
    }

    @objc public static func get(_ ptr: UInt) -> TextRgba? {
        lock.lock()
        defer { lock.unlock() }
        return live[ptr]
    }
}

@objc public class TextRgba: NSObject, FlutterTexture {
    public var textureId: Int64 = -1
    private var registry: FlutterTextureRegistry?
    private var data: CVPixelBuffer?
    private var width: Int = 0
    private var height: Int = 0
    private var consumed: UInt64 = 0
    private var pool: CVPixelBufferPool?
    private let queue = DispatchQueue(label: "text_rgba_sync_queue")

    public static func new(registry: FlutterTextureRegistry?) -> TextRgba {
        let textRgba = TextRgba()
        textRgba.registry = registry
        textRgba.textureId = registry?.register(textRgba) ?? -1
        // A failed registration is reported as -1 and never closed; keeping
        // it out of the registry avoids retaining it forever.
        if textRgba.textureId != -1 {
            TextureRgbaRegistry.add(textRgba)
        }
        return textRgba
    }

    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        queue.sync {
            if (data == nil) {
                return nil
            }
            consumed &+= 1
            return Unmanaged.passRetained(data!)
        }
    }

    @objc public func getConsumed() -> UInt64 {
        queue.sync {
            consumed
        }
    }

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = pool, self.width == width, self.height == height {
            return pool
        }
        pool = nil
        // macOS only support 32BGRA currently.
        let dict: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferOpenGLCompatibilityKey as String: true,
            // IOSurface backing is what the engine's Metal texture cache expects.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            // https://developer.apple.com/forums/thread/712709
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, dict as CFDictionary, &pool)
        return pool
    }

    private func _markFrameAvaliable(buffer: UnsafePointer<UInt8>, len: Int, width: Int, height: Int, stride_align: Int) -> Bool {
        var pixelBufferCopy: CVPixelBuffer?
        // Reusing pooled buffers keeps the engine's CVMetalTextureCache
        // entries stable; a fresh buffer per frame churns the cache and
        // widens the engine's texture lifetime race (flutter/flutter#157379).
        guard let pool = ensurePool(width: width, height: height) else {
            return false
        }
        let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferCopy)
        guard result == kCVReturnSuccess else {
            return false
        }

        CVPixelBufferLockBaseAddress(pixelBufferCopy!, [])
        let ptr = CVPixelBufferGetBaseAddress(pixelBufferCopy!)!
        memcpy(ptr, buffer, min(len, CVPixelBufferGetDataSize(pixelBufferCopy!)))
        CVPixelBufferUnlockBaseAddress(pixelBufferCopy!, [])
        self.data = pixelBufferCopy
        self.width = width
        self.height = height
        if textureId != -1 && self.data != nil {
            registry?.textureFrameAvailable(textureId)
            return true
        } else {
            return false
        }
    }

    /// Take a decoded GPU frame over. `pixelBuffer` is borrowed and only valid
    /// for this call: storing it in the strong `data` property is what keeps it
    /// alive afterwards (ARC owns that +1; no explicit CVPixelBufferRetain).
    ///
    /// Returns false when the frame is refused, and then changes no state, so the
    /// caller can still fall back to the RGBA path.
    @objc public func markFrameAvailable(pixelBuffer: CVPixelBuffer, width: Int, height: Int, pixfmt: UInt32) -> Bool {
        // Take the ticket inside the critical section, notify outside it: the
        // Flutter registry callback must not run while the queue is held, or a
        // re-entrant call from the engine would deadlock.
        let ticket: Int64? = queue.sync {
            guard textureId != -1, registry != nil else { return nil }
            guard width > 0, height > 0 else { return nil }

            // The buffer, not the caller, is the authority on the format: the
            // engine reads it straight from the buffer, so accepting a buffer
            // whose own format disagrees with `pixfmt` would present the frame as
            // something it is not. A mismatch means the two sides disagree about
            // what was decoded, which is a reason to refuse rather than to guess.
            let bufferFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            guard bufferFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                  bufferFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
            guard bufferFormat == pixfmt else { return nil }

            // The engine builds its textures with
            // CVMetalTextureCacheCreateTextureFromImage, which needs an
            // IOSurface-backed buffer. NV12 alone does not imply one: a buffer
            // without an IOSurface would be accepted here and then refused by the
            // engine, after this method had already said yes and the caller had
            // already skipped the RGBA fallback.
            guard CVPixelBufferGetIOSurface(pixelBuffer) != nil else { return nil }

            self.data = pixelBuffer
            self.width = width
            self.height = height
            return textureId
        }
        guard let id = ticket else { return false }
        registry?.textureFrameAvailable(id)
        return true
    }

    @objc public func markFrameAvaliableRaw(buffer: UnsafePointer<UInt8>, len: Int, width: Int, height: Int, stride_align: Int) -> Bool {
        queue.sync {
            _markFrameAvaliable(buffer: buffer, len: len, width: width, height: height, stride_align: stride_align)
        }
    }


    @objc public func markFrameAvaliable(data: Data, width: Int, height: Int, stride_align: Int) -> Bool {
        data.withUnsafeBytes { buffer in
            markFrameAvaliableRaw(
                buffer: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                len: data.count,
                width: width,
                height: height,
                stride_align: stride_align)
        }
    }
}
