#include <assert.h>
#include "include/texture_rgba_renderer/texture_rgba_renderer_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "texture_rgba_renderer_plugin.h"
#include "texture_rgba.h"

void TextureRgbaRendererPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar)
{
    texture_rgba_renderer::TextureRgbaRendererPlugin::RegisterWithRegistrar(
        flutter::PluginRegistrarManager::GetInstance()
            ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

void FlutterRgbaRendererPluginOnRgba(void *texture_rgba, const uint8_t *buffer, int len, int width, int height, int stride_align)
{
    assert(buffer != nullptr);
    assert(width > 0 && height > 0);
    if (texture_rgba == nullptr || buffer == nullptr || width <= 0 || height <= 0)
    {
        return;
    }

    // The pointer may already have been closed by the Dart side; the push
    // validates it against the live-object set instead of dereferencing.
    TextureRgbaPush(texture_rgba, buffer, len, width, height);
}

uint64_t FlutterRgbaRendererPluginGetConsumed(void *texture_rgba)
{
    if (texture_rgba == nullptr)
    {
        return 0;
    }
    return TextureRgbaConsumed(texture_rgba);
}
