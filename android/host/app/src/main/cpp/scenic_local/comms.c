/*
 * Minimal comms adapter for Android Scenic renderer.
 */

#include <string.h>
#include <android/log.h>

#include "comms.h"

#define LOG_TAG "ScenicNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static const unsigned char* g_stream_ptr = NULL;
static int g_stream_remaining = 0;

void comms_set_buffer(const void* data, int len) {
  g_stream_ptr = (const unsigned char*)data;
  g_stream_remaining = len;
}

bool read_bytes_down(void* p_buff, int bytes_to_read, int* p_bytes_remaining) {
  if (bytes_to_read <= 0) return true;
  if (g_stream_ptr == NULL || g_stream_remaining < bytes_to_read) {
    return false;
  }

  memcpy(p_buff, g_stream_ptr, bytes_to_read);
  g_stream_ptr += bytes_to_read;
  g_stream_remaining -= bytes_to_read;
  if (p_bytes_remaining) {
    *p_bytes_remaining -= bytes_to_read;
  }
  return true;
}

void send_puts(const char* msg) {
  if (msg) {
    LOGI("%s", msg);
  }
}

void log_info(const char* msg) {
  if (msg) {
    LOGI("%s", msg);
  }
}

void log_warn(const char* msg) {
  if (msg) {
    LOGW("%s", msg);
  }
}

void log_error(const char* msg) {
  if (msg) {
    LOGE("%s", msg);
  }
}

void send_ready() {
  // no-op for Android
}
