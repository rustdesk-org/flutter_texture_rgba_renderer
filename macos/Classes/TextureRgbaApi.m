//
//  TextureRgbaApi.m
//  texture_rgba_renderer
//
//  Created by kingtous on 2023/2/19.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "texture_rgba_renderer/texture_rgba_renderer-Swift.h"

#if __cplusplus
extern "C" {
#endif

/// Keep the same name with Windows.
/// The pointer may already have been closed by the Dart side; resolve it
/// through the live-object registry (which retains) instead of dereferencing.
/// The calling Rust thread has no autorelease pool, so provide one.
void FlutterRgbaRendererPluginOnRgba(void* texture_rgba_ptr, const uint8_t* buffer, int len, int width, int height, int stride_align) {
    @autoreleasepool {
        TextRgba* texture_rgba = [TextureRgbaRegistry get:(NSUInteger)texture_rgba_ptr];
        if (texture_rgba == nil) {
            return;
        }
        [texture_rgba markFrameAvaliableRawWithBuffer:buffer len:len width:width height:height stride_align: stride_align];
    }
}

/// Keep the same name with Windows.
uint64_t FlutterRgbaRendererPluginGetConsumed(void* texture_rgba_ptr) {
    @autoreleasepool {
        TextRgba* texture_rgba = [TextureRgbaRegistry get:(NSUInteger)texture_rgba_ptr];
        if (texture_rgba == nil) {
            return 0;
        }
        return [texture_rgba getConsumed];
    }
}

/// Zero-copy entry point: hand a decoded CVPixelBuffer over without a copy.
///
/// `pixel_buffer` is borrowed and only valid during this call; the receiver
/// takes its own reference when it keeps the frame. Returns 1 when the frame
/// was taken over and will be presented, 0 when it was refused - the caller
/// must then deliver the same decoded frame through the RGBA path.
///
/// The pointer is resolved through `TextureRgbaRegistry` rather than bridged
/// directly: the Dart side may already have closed the texture, and this call
/// races with that by nature (the decoder hands out frames while the window can
/// be closing). The calling Rust thread has no autorelease pool, so provide one.
int32_t FlutterRgbaRendererPluginOnPixelBuffer(void* texture_rgba_ptr, void* pixel_buffer, int32_t width, int32_t height, uint32_t pixfmt) {
    if (texture_rgba_ptr == NULL || pixel_buffer == NULL) {
        return 0;
    }
    @autoreleasepool {
        TextRgba* texture_rgba = [TextureRgbaRegistry get:(NSUInteger)texture_rgba_ptr];
        if (texture_rgba == nil) {
            return 0;
        }
        BOOL accepted = [texture_rgba markFrameAvailableWithPixelBuffer:(CVPixelBufferRef)pixel_buffer
                                                                  width:width
                                                                 height:height
                                                                 pixfmt:pixfmt];
        return accepted ? 1 : 0;
    }
}

#if __cplusplus
} //Extern C
#endif
