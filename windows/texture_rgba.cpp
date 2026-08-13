#include "texture_rgba.h"
#include <iostream>
#include <shared_mutex>
#include <unordered_set>

namespace
{
	// Membership is checked under a shared lock on every push, so removal
	// (unique lock, in ~TextureRgba) drains in-flight pushes before the
	// object's memory goes away.
	std::shared_mutex g_live_mutex;
	std::unordered_set<void *> g_live_textures;
}

TextureRgba::TextureRgba(flutter::TextureRegistrar *texture_registrar)
{
	this->texture_registrar_ = texture_registrar;
	// TODO: flutter only support PixelBuffer in 2023.02.17.
	auto buffer = flutter::PixelBufferTexture([=](size_t width, size_t height) -> const FlutterDesktopPixelBuffer *
											  { return this->buffer(); });
	texture_ = std::make_unique<flutter::TextureVariant>(buffer);
	this->texture_id_ = texture_registrar->RegisterTexture(texture_.get());
	{
		std::unique_lock<std::shared_mutex> lock(g_live_mutex);
		g_live_textures.insert(this);
	}
}

TextureRgba::~TextureRgba()
{
	// Unregistration happens in closeTexture; here only make sure no push is
	// still running on this object and no later push can reach it.
	std::unique_lock<std::shared_mutex> lock(g_live_mutex);
	g_live_textures.erase(this);
}

void TextureRgba::MarkVideoFrameAvailable(
	std::vector<uint8_t> &buffer, size_t width, size_t height)
{
	if (buffer.empty())
	{
		return;
	}

	// Do not check bellow. Because the data may have paddings per row.
	// buffer.size() != width * height * 4

	const std::lock_guard<std::mutex> lock(mutex_);
	int bg_index = fg_index_ ^ 1;
	buffer.swap(buffer_tmp_[bg_index]);
	width_[bg_index] = width;
	height_[bg_index] = height;
	if (!buff_ready_)
	{
		buff_ready_ = true;
		texture_registrar_->MarkTextureFrameAvailable(texture_id_);
	}
}

void TextureRgba::MarkVideoFrameAvailable2(const uint8_t* buffer, const size_t buffer_length, size_t width, size_t height) {
	if (!buffer  || buffer_length < width * height * 4)
	{
		return;
	}
	const std::lock_guard<std::mutex> lock(mutex_);
	int bg_index = fg_index_ ^ 1;
	buffer_tmp_[bg_index].assign(buffer, buffer + buffer_length);
	width_[bg_index] = width;
	height_[bg_index] = height;
	if (!buff_ready_)
	{
		buff_ready_ = true;
		texture_registrar_->MarkTextureFrameAvailable(texture_id_);
	}
}

// This function may be called
// event texture_registrar_->MarkTextureFrameAvailable(texture_id_); is not called before.
inline const FlutterDesktopPixelBuffer *TextureRgba::buffer()
{
	const std::lock_guard<std::mutex> lock(mutex_);
	if (buff_ready_)
	{
		fg_index_ ^= 1;
		flutter_pixel_buffer_.buffer = static_cast<const uint8_t *>(buffer_tmp_[fg_index_].data());
		flutter_pixel_buffer_.width = width_[fg_index_];
		flutter_pixel_buffer_.height = height_[fg_index_];
		buff_ready_ = false;
		consumed_.fetch_add(1, std::memory_order_relaxed);
	}
	return &this->flutter_pixel_buffer_;
}

bool TextureRgbaPush(void *texture_rgba, const uint8_t *buffer, int len, int width, int height)
{
	std::shared_lock<std::shared_mutex> lock(g_live_mutex);
	if (g_live_textures.find(texture_rgba) == g_live_textures.end())
	{
		return false;
	}
	static_cast<TextureRgba *>(texture_rgba)->MarkVideoFrameAvailable2(buffer, len, width, height);
	return true;
}

uint64_t TextureRgbaConsumed(void *texture_rgba)
{
	std::shared_lock<std::shared_mutex> lock(g_live_mutex);
	if (g_live_textures.find(texture_rgba) == g_live_textures.end())
	{
		return 0;
	}
	return static_cast<TextureRgba *>(texture_rgba)->consumed();
}
