#include "include/texture_rgba_renderer/texture_rgba_renderer_plugin.h"
#include "include/texture_rgba_renderer/texture_rgba_renderer.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#define TEXTURE_RGBA_RENDERER_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), texture_rgba_renderer_plugin_get_type(), \
                              TextureRgbaRendererPlugin))

#include <cstring>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>
#include <unordered_set>

std::unordered_map<int64_t, TextureRgba *> g_renderer_map;

// Rust's video thread pushes frames through a raw TextureRgba pointer with no
// lifetime contract; membership is checked under a shared lock on every push
// so closeTexture (unique lock) can safely release the object.
// shared_timed_mutex: this target builds as C++14.
static std::shared_timed_mutex g_live_mutex;
static std::unordered_set<void *> g_live_textures;

void FlutterRgbaRendererPluginOnRgba(void *texture_rgba_ptr, const uint8_t *buffer, int len, int width, int height);
struct _TextureRgbaRendererPlugin
{
  GObject parent_instance;
  FlTextureRegistrar *texture_registrar;
};

G_DEFINE_TYPE(TextureRgbaRendererPlugin, texture_rgba_renderer_plugin, g_object_get_type())

// Called when a method call is received from Flutter.
static void texture_rgba_renderer_plugin_handle_method_call(
    TextureRgbaRendererPlugin *self,
    FlMethodCall *method_call)
{
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar *method = fl_method_call_get_name(method_call);

  if (strcmp(method, "createTexture") == 0)
  {
    auto args = fl_method_call_get_args(method_call);
    int64_t key = fl_value_get_int(fl_value_lookup_string(args, "key"));
    if (g_renderer_map.find(key) != g_renderer_map.end())
    {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_int(-1)));
    }
    else
    {
      TextureRgba* texture_rgba = texture_rgba_new(self->texture_registrar);
      auto texture_id = reinterpret_cast<int64_t>(FL_TEXTURE(texture_rgba));
      texture_rgba->texture_id = texture_id;
      g_renderer_map.insert(std::make_pair(key, texture_rgba));
      {
        const std::unique_lock<std::shared_timed_mutex> lock(g_live_mutex);
        g_live_textures.insert(texture_rgba);
      }
      // Register to the registrar.
      fl_texture_registrar_register_texture(self->texture_registrar, FL_TEXTURE(texture_rgba));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_int(texture_id)));
    }
  }
  else if (strcmp(method, "closeTexture") == 0)
  {
    auto args = fl_method_call_get_args(method_call);
    int64_t key = fl_value_get_int(fl_value_lookup_string(args, "key"));
    if (g_renderer_map.find(key) != g_renderer_map.end())
    {
      TextureRgba *texture_rgba = g_renderer_map[key];
      {
        // Drain Rust-side pushes before tearing the texture down.
        const std::unique_lock<std::shared_timed_mutex> lock(g_live_mutex);
        g_live_textures.erase(texture_rgba);
      }
      texture_rgba_terminate(texture_rgba);
      fl_texture_registrar_unregister_texture(self->texture_registrar, FL_TEXTURE(texture_rgba));
      // The raster thread may still borrow the FlTexture for the frame in
      // flight (the registrar hands out unowned pointers) and the embedder
      // offers no completion barrier, so this stays a heuristic: the object
      // used to be leaked forever to dodge that; release it after a grace
      // long enough that only a terminally hung raster thread (a dead session
      // anyway) could still be inside populate.
      g_timeout_add_seconds(10, [](gpointer data) -> gboolean {
        g_object_unref(data);
        return G_SOURCE_REMOVE;
      }, texture_rgba);
      g_renderer_map.erase(key);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(true)));
  }
  else if (strcmp(method, "onRgba") == 0)
  {
    auto args = fl_method_call_get_args(method_call);
    auto key = fl_value_get_int(fl_value_lookup_string(args, "key"));
    auto data = fl_value_get_uint8_list(fl_value_lookup_string(args, "data"));
    auto data_length = fl_value_get_length(fl_value_lookup_string(args, "data"));
    auto width = fl_value_get_int(fl_value_lookup_string(args, "width"));
    auto height = fl_value_get_int(fl_value_lookup_string(args, "height"));
    auto stride_align = fl_value_get_int(fl_value_lookup_string(args, "stride_align"));
    auto it = g_renderer_map.find(key);
    if (it == g_renderer_map.end())
    {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(false)));
    }
    else
    {
      auto texture_rgba = it->second;
      FlutterRgbaRendererPluginOnRgba((void*)texture_rgba, data, data_length, width, height, stride_align);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(
          fl_value_new_bool(fl_texture_registrar_mark_texture_frame_available(self->texture_registrar, FL_TEXTURE(texture_rgba)))));
    }
  }
  else if (strcmp(method, "getTexturePtr") == 0)
  {
    auto args = fl_method_call_get_args(method_call);
    auto key = fl_value_get_int(fl_value_lookup_string(args, "key"));
    if (g_renderer_map.find(key) == g_renderer_map.end())
    {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(
          fl_value_new_int(0)));
    }
    else
    {
      // Return an address.
      size_t rgba = reinterpret_cast<size_t>((void *)g_renderer_map[key]);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(
          fl_value_new_int(rgba)));
    }
  }
  else
  {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void texture_rgba_renderer_plugin_dispose(GObject *object)
{
  G_OBJECT_CLASS(texture_rgba_renderer_plugin_parent_class)->dispose(object);
}

static void texture_rgba_renderer_plugin_class_init(TextureRgbaRendererPluginClass *klass)
{
  G_OBJECT_CLASS(klass)->dispose = texture_rgba_renderer_plugin_dispose;
}

static void texture_rgba_renderer_plugin_init(TextureRgbaRendererPlugin *self) {}

static void method_call_cb(FlMethodChannel *channel, FlMethodCall *method_call,
                           gpointer user_data)
{
  TextureRgbaRendererPlugin *plugin = TEXTURE_RGBA_RENDERER_PLUGIN(user_data);
  texture_rgba_renderer_plugin_handle_method_call(plugin, method_call);
}

void texture_rgba_renderer_plugin_register_with_registrar(FlPluginRegistrar *registrar)
{
  TextureRgbaRendererPlugin *plugin = TEXTURE_RGBA_RENDERER_PLUGIN(
      g_object_new(texture_rgba_renderer_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "texture_rgba_renderer",
                            FL_METHOD_CODEC(codec));
  plugin->texture_registrar = fl_plugin_registrar_get_texture_registrar(registrar);
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}


extern "C" {
   void FlutterRgbaRendererPluginOnRgba(void *texture_rgba_ptr, const uint8_t *buffer, int len, int width, int height, int stride_align) {
      // Check whether the parameter is valid.
      if (width == 0 || height == 0) {
        g_warning("The width, height is not valid, ignoring this request.");
        return;
      }
      // The pointer may already have been closed by the Dart side; holding
      // the shared lock across the push keeps close from freeing it mid-call
      // without serializing pushes of different displays against each other.
      const std::shared_lock<std::shared_timed_mutex> live_lock(g_live_mutex);
      if (g_live_textures.find(texture_rgba_ptr) == g_live_textures.end()) {
        return;
      }
      TextureRgba* self = TEXTURE_RGBA(texture_rgba_ptr);
      g_mutex_lock(&self->mutex);
      // selfate has registered a texture_id,
      if (self->texture_id != 0 && !g_atomic_int_get(&self->buffer_ready) && !texture_rgba_is_terminate(self)) {
        // copy data to the texture.
        auto copied_data = new uint8_t[len];
        memcpy(copied_data, buffer, len);
        // It's safe to working on a non reading index
        g_atomic_pointer_set(&self->buffer, copied_data);
        g_atomic_int_set(&self->video_height, height);
        g_atomic_int_set(&self->video_width, width);
        g_atomic_int_set(&self->buffer_ready, TRUE);
        fl_texture_registrar_mark_texture_frame_available(
          self->texture_registrar,
          FL_TEXTURE(self)
        );
      }
      g_mutex_unlock(&self->mutex);
   }

   uint64_t FlutterRgbaRendererPluginGetConsumed(void *texture_rgba_ptr) {
      const std::shared_lock<std::shared_timed_mutex> live_lock(g_live_mutex);
      if (g_live_textures.find(texture_rgba_ptr) == g_live_textures.end()) {
        return 0;
      }
      TextureRgba* self = TEXTURE_RGBA(texture_rgba_ptr);
      g_mutex_lock(&self->mutex);
      uint64_t consumed = self->consumed;
      g_mutex_unlock(&self->mutex);
      return consumed;
   }
};
