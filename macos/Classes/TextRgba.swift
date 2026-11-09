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

    @objc public func markFrameAvaliableRaw(buffer: UnsafePointer<UInt8>, len: Int, width: Int, height: Int, stride_align: Int) -> Bool {
        queue.sync {
            _markFrameAvaliable(buffer: buffer, len: len, width: width, height: height, stride_align: stride_align)
        }
    }

    /// Shows a decoded frame without copying it. Flutter's macOS external
    /// texture samples 32BGRA and bi-planar 4:2:0 (NV12) buffers directly, so
    /// a VideoToolbox output buffer can be handed over as is. The buffer must
    /// not be written to afterwards. It is retained until the next frame.
    @discardableResult
    @objc public func markFrameAvaliable(pixelBuffer: CVPixelBuffer) -> Bool {
        // width/height describe the RGBA pool, which ensurePool reuses when
        // they match, so a frame that bypasses the pool must not change them.
        queue.sync {
            self.data = pixelBuffer
        }
        if textureId != -1 {
            registry?.textureFrameAvailable(textureId)
            return true
        }
        return false
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
