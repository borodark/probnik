/*
 * Minimal comms adapter for Android Scenic renderer.
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifndef __BYTE_ORDER__
#define __BYTE_ORDER__ __ORDER_LITTLE_ENDIAN__
#endif

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
  #define ntoh_ui16(x) (x)
  #define ntoh_ui32(x) (x)
  #define ntoh_f32(x) (x)
  #define hton_ui16(x) (x)
  #define hton_ui32(x) (x)
  #define hton_f32(x) (x)
#else
  #define ntoh_ui16(x) (((x) >> 8) | ((x) << 8))
  #define ntoh_ui32(x) \
    (((x) >> 24) | (((x) &0x00FF0000) >> 8) | (((x) &0x0000FF00) << 8) | ((x) << 24))
  static inline float ntoh_f32(float f) {
    union {
      unsigned int i;
      float f;
    } sw;
    sw.f = f;
    sw.i = ntoh_ui32(sw.i);
    return sw.f;
  }
  #define hton_ui16(x) (ntoh_ui16(x))
  #define hton_ui32(x) (ntoh_ui32(x))
  #define hton_f32(x) (ntoh_f32(x))
#endif

// Set the current input buffer for read_bytes_down.
void comms_set_buffer(const void* data, int len);

bool read_bytes_down(void* p_buff, int bytes_to_read, int* p_bytes_remaining);

void send_puts(const char* msg);
void log_info(const char* msg);
void log_warn(const char* msg);
void log_error(const char* msg);

// No-op stubs for unused callbacks
void send_ready();
