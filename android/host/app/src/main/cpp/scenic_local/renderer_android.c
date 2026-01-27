/*
 * Android Scenic renderer wrapper.
 */

#include <string.h>
#include <GLES3/gl3.h>

#include "renderer_android.h"
#include "comms.h"
#include "script.h"
#include "font.h"
#include "image.h"
#include "utils.h"
#define NANOVG_GLES3
#include "nanovg/nanovg_gl.h"
#include "device/device.h"

static NVGcontext* g_ctx = NULL;
static int g_width = 0;
static int g_height = 0;
static float g_ratio = 1.0f;
static float g_global_tx[6] = {1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f};

static void ensure_context() {
  if (g_ctx) return;

  init_scripts();
  init_fonts();
  init_images();

  g_ctx = nvgCreateGLES3(NVG_ANTIALIAS | NVG_STENCIL_STROKES);
}

void scenic_android_init(int width, int height, float ratio) {
  g_width = width;
  g_height = height;
  g_ratio = (ratio > 0.0f) ? ratio : 1.0f;
  ensure_context();
}

void scenic_android_resize(int width, int height, float ratio) {
  g_width = width;
  g_height = height;
  if (ratio > 0.0f) {
    g_ratio = ratio;
  }
}

void scenic_android_shutdown() {
  if (g_ctx) {
    nvgDeleteGLES3(g_ctx);
    g_ctx = NULL;
  }
}

void scenic_android_set_clear_color(float r, float g, float b, float a) {
  device_clear_color(r, g, b, a);
}

void scenic_android_put_script(const void* data, int len) {
  if (!data || len <= 0) return;
  ensure_context();
  int remaining = len;
  comms_set_buffer(data, len);
  put_script(&remaining);
}

void scenic_android_delete_script(const void* data, int len) {
  if (!data || len <= 0) return;
  int remaining = len;
  comms_set_buffer(data, len);
  delete_script(&remaining);
}

void scenic_android_reset() {
  reset_scripts();
}

void scenic_android_put_font(const void* data, int len) {
  if (!data || len <= 0) return;
  ensure_context();
  int remaining = len;
  comms_set_buffer(data, len);
  put_font(&remaining, g_ctx);
}

void scenic_android_put_image(const void* data, int len) {
  if (!data || len <= 0) return;
  ensure_context();
  int remaining = len;
  comms_set_buffer(data, len);
  put_image(&remaining, g_ctx);
}

void scenic_android_render() {
  if (!g_ctx || g_width <= 0 || g_height <= 0) return;

  device_begin_render();

  nvgBeginFrame(g_ctx, g_width, g_height, g_ratio);
  nvgTransform(g_ctx,
    g_global_tx[0], g_global_tx[1],
    g_global_tx[2], g_global_tx[3],
    g_global_tx[4], g_global_tx[5]
  );

  sid_t id;
  id.p_data = "_root_";
  id.size = strlen(id.p_data);
  render_script(id, g_ctx);

  nvgEndFrame(g_ctx);
  device_end_render();
}
