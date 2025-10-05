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

typedef struct {
  const unsigned char* data;
  size_t len;
  const char* name;
} mcore_font_blob_t;

typedef struct {
  const char* utf8;
  float wrap_width;
  float font_size_px;
  int font_id;
} mcore_text_req_t;

typedef struct {
  float advance_w;
  float advance_h;
  int line_count;
} mcore_text_metrics_t;

typedef struct {
  float width;
  float height;
} mcore_text_size_t;

typedef enum {
  MCORE_DRAW_CMD_ROUNDED_RECT = 0,
  MCORE_DRAW_CMD_TEXT = 1,
} mcore_draw_cmd_kind_t;

typedef struct {
  mcore_draw_cmd_kind_t kind;
  float x, y, width, height, radius;
  float color[4];
  const char* text_ptr;
  float font_size;
  float wrap_width;
  int font_id;
  unsigned char _padding[12];
} mcore_draw_command_t;

typedef enum { MCORE_OK = 0, MCORE_ERR = 1 } mcore_status_t;

// Text input events
typedef enum {
  TEXT_EVENT_INSERT_CHAR = 0,
  TEXT_EVENT_BACKSPACE = 1,
  TEXT_EVENT_DELETE = 2,
  TEXT_EVENT_MOVE_CURSOR = 3,
  TEXT_EVENT_SET_CURSOR = 4,
  TEXT_EVENT_INSERT_TEXT = 5,
} mcore_text_event_kind_t;

typedef enum {
  CURSOR_LEFT = 0,
  CURSOR_RIGHT = 1,
  CURSOR_HOME = 2,
  CURSOR_END = 3,
} mcore_cursor_direction_t;

typedef struct {
  mcore_text_event_kind_t kind;
  unsigned int char_code;  // For INSERT_CHAR
  mcore_cursor_direction_t direction;  // For MOVE_CURSOR
  unsigned char extend_selection;  // Shift key held
  int cursor_position;  // For SET_CURSOR
  const char* text_ptr;  // For INSERT_TEXT
} mcore_text_event_t;

// Lifecycle
mcore_context_t* mcore_create(const mcore_surface_desc_t* desc);
void             mcore_destroy(mcore_context_t* ctx);

// Resize/DPI
void mcore_resize(mcore_context_t* ctx, const mcore_surface_desc_t* desc);

// Resources
int mcore_font_register(mcore_context_t* ctx, const mcore_font_blob_t* blob);

// Frame
void mcore_begin_frame(mcore_context_t* ctx, double time_seconds);
void mcore_rect_rounded(mcore_context_t* ctx, const mcore_rounded_rect_t* rect);
void mcore_text_layout(mcore_context_t* ctx, const mcore_text_req_t* req, mcore_text_metrics_t* out);
void mcore_measure_text(mcore_context_t* ctx, const char* text, float font_size, float max_width, mcore_text_size_t* out);
void mcore_text_draw(mcore_context_t* ctx, const mcore_text_req_t* req, float x, float y, mcore_rgba_t color);
void mcore_render_commands(mcore_context_t* ctx, const mcore_draw_command_t* commands, int count);
mcore_status_t mcore_end_frame_present(mcore_context_t* ctx, mcore_rgba_t clear);

// Text input
unsigned char mcore_text_input_event(mcore_context_t* ctx, unsigned long long id, const mcore_text_event_t* event);
int mcore_text_input_get(mcore_context_t* ctx, unsigned long long id, char* buf, int buf_len);
int mcore_text_input_cursor(mcore_context_t* ctx, unsigned long long id);
void mcore_text_input_set(mcore_context_t* ctx, unsigned long long id, const char* text);

// Text selection
unsigned char mcore_text_input_get_selection(mcore_context_t* ctx, unsigned long long id, int* out_start, int* out_end);
void mcore_text_input_set_cursor_pos(mcore_context_t* ctx, unsigned long long id, int byte_offset, unsigned char extend_selection);
int mcore_text_input_get_selected_text(mcore_context_t* ctx, unsigned long long id, char* buf, int buf_len);
void mcore_text_input_start_selection(mcore_context_t* ctx, unsigned long long id, int byte_offset);

// Text measurement at cursor
float mcore_measure_text_to_byte_offset(mcore_context_t* ctx, const char* text, float font_size, int byte_offset);

// Clipping
void mcore_push_clip_rect(mcore_context_t* ctx, float x, float y, float width, float height);
void mcore_pop_clip(mcore_context_t* ctx);

// Diagnostics
const char* mcore_last_error(void);

#ifdef __cplusplus
}
#endif
