/*
 * Android GLES device adapter for Scenic renderer.
 */

#include <GLES3/gl3.h>
#include <stdio.h>

#include "device.h"

static float g_clear_color[4] = {0.0f, 0.0f, 0.0f, 1.0f};

int device_init(const device_opts_t* p_opts, device_info_t* p_info) {
  (void)p_opts;
  (void)p_info;
  return 0;
}

int device_close(device_info_t* p_info) {
  (void)p_info;
  return 0;
}

void device_poll() {
}

void device_begin_render() {
  glClearColor(g_clear_color[0], g_clear_color[1], g_clear_color[2], g_clear_color[3]);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
}

void device_end_render() {
}

void device_clear_color(float red, float green, float blue, float alpha) {
  g_clear_color[0] = red;
  g_clear_color[1] = green;
  g_clear_color[2] = blue;
  g_clear_color[3] = alpha;
}

char* device_gl_error() {
  GLenum err = glGetError();
  if (err == GL_NO_ERROR) {
    return NULL;
  }
  static char buff[64];
  snprintf(buff, sizeof(buff), "GL error: 0x%04x", err);
  return buff;
}
