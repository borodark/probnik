/*
 * Android Scenic renderer wrapper.
 */

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void scenic_android_init(int width, int height, float ratio);
void scenic_android_resize(int width, int height, float ratio);
void scenic_android_shutdown();

void scenic_android_set_clear_color(float r, float g, float b, float a);

void scenic_android_put_script(const void* data, int len);
void scenic_android_delete_script(const void* data, int len);
void scenic_android_reset();

void scenic_android_put_font(const void* data, int len);
void scenic_android_put_image(const void* data, int len);

void scenic_android_render();

#ifdef __cplusplus
}
#endif
