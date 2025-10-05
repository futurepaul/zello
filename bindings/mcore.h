#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct mcore_context mcore_context_t;

typedef enum {
  MCORE_PLATFORM_MACOS = 1,
  MCORE_PLATFORM_WINDOWS = 2,
  MCORE_PLATFORM_X11 = 3,
  MCORE_PLATFORM_WAYLAND = 4,
} mcore_platform_t;

typedef struct {
  void* ns_view;        // NSView*
  void* ca_metal_layer; // CAMetalLayer*
  float scale_factor;
  int   width_px;
  int   height_px;
} mcore_macos_surface_t;

typedef union {
  mcore_macos_surface_t macos;
} mcore_surface_union_t;

typedef struct {
  mcore_platform_t platform;
  mcore_surface_union_t u;
} mcore_surface_desc_t;

typedef struct { float r,g,b,a; } mcore_rgba_t;

typedef struct {
  float x, y, w, h;
  float radius;
  mcore_rgba_t fill;
} mcore_rounded_rect_t;

typedef enum { MCORE_OK = 0, MCORE_ERR = 1 } mcore_status_t;

// Lifecycle
mcore_context_t* mcore_create(const mcore_surface_desc_t* desc);
void             mcore_destroy(mcore_context_t* ctx);

// Resize/DPI
void mcore_resize(mcore_context_t* ctx, const mcore_surface_desc_t* desc);

// Frame
void mcore_begin_frame(mcore_context_t* ctx, double time_seconds);
void mcore_rect_rounded(mcore_context_t* ctx, const mcore_rounded_rect_t* rect);
mcore_status_t mcore_end_frame_present(mcore_context_t* ctx, mcore_rgba_t clear);

// Diagnostics
const char* mcore_last_error(void);

#ifdef __cplusplus
}
#endif
