//
//  TextureRgbaApi.m
//  texture_rgba_renderer
//
//  Created by kingtous on 2023/2/19.
//

#import <Foundation/Foundation.h>
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

#if __cplusplus
} //Extern C
#endif
