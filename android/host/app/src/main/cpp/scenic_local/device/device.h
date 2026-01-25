/*
 * Minimal Android device adapter for Scenic renderer.
 */

#pragma once

#include "types.h"

int device_init(const device_opts_t* p_opts, device_info_t* p_info);
int device_close(device_info_t* p_info);
void device_poll();

void device_begin_render();
void device_end_render();

void device_clear_color(float red, float green, float blue, float alpha);
char* device_gl_error();
