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
  MCORE_DRAW_CMD_PUSH_CLIP = 2,
  MCORE_DRAW_CMD_POP_CLIP = 3,
  MCORE_DRAW_CMD_STYLED_RECT = 4,
} mcore_draw_cmd_kind_t;

typedef struct {
  mcore_draw_cmd_kind_t kind;
  float x, y, width, height, radius;
  float color[4];  // Fill color (or text color)
  const char* text_ptr;
  float font_size;
  float wrap_width;
  int font_id;

  // Border fields
  float border_width;
  float border_color[4];
  unsigned char has_border;  // 0 or 1

  // Shadow fields
  float shadow_offset_x;
  float shadow_offset_y;
  float shadow_blur;
  float shadow_color[4];
  unsigned char has_shadow;  // 0 or 1

  unsigned char _padding[2];
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

// IME (Input Method Editor) support
typedef struct {
  const char* text;
  int cursor_offset;  // Cursor position within preedit text
} mcore_ime_preedit_t;

// Set IME preedit (composition) text for a text input
void mcore_ime_set_preedit(mcore_context_t* ctx, unsigned long long id, const mcore_ime_preedit_t* preedit);

// Commit IME text (finalize composition)
void mcore_ime_commit(mcore_context_t* ctx, unsigned long long id, const char* text);

// Clear IME preedit state
void mcore_ime_clear_preedit(mcore_context_t* ctx, unsigned long long id);

// Get IME preedit text if any
unsigned char mcore_ime_get_preedit(mcore_context_t* ctx, unsigned long long id, char* buf, int buf_len, int* out_cursor_offset);

// Clipping
void mcore_push_clip_rect(mcore_context_t* ctx, float x, float y, float width, float height);
void mcore_pop_clip(mcore_context_t* ctx);

// Diagnostics
const char* mcore_last_error(void);

// ============================================================================
// Accessibility (AccessKit)
// ============================================================================

typedef struct {
    float x;
    float y;
    float width;
    float height;
} mcore_rect_t;

typedef struct {
    unsigned long long id;
    unsigned char role;  // Maps to AccessKit Role enum
    const char* label;
    mcore_rect_t bounds;
    unsigned int actions;  // Bitfield of supported actions
    const unsigned long long* children;
    int children_count;
    const char* value;
    int text_selection_start;
    int text_selection_end;
} mcore_a11y_node_t;

// Initialize accessibility for a given NSView
void mcore_a11y_init(mcore_context_t* ctx, void* ns_view);

// Update the accessibility tree
void mcore_a11y_update(
    mcore_context_t* ctx,
    const mcore_a11y_node_t* nodes,
    int node_count,
    unsigned long long root_id,
    unsigned long long focus_id
);

// Set callback for accessibility actions
// Callback signature: void callback(unsigned long long widget_id, unsigned char action_code)
// Action codes: 0 = Focus, 1 = Click
void mcore_a11y_set_action_callback(void (*callback)(unsigned long long, unsigned char));

// ============================================================================
// Color Support
// ============================================================================

// Color type (matches Rust color::AlphaColor<Srgb>)
// Same memory layout as [4]f32 (r, g, b, a)
typedef struct {
    float r;
    float g;
    float b;
    float a;
} mcore_color_t;

// Parse a CSS color string into mcore_color_t
// Supports: oklch(), rgb(), rgba(), hex (#rrggbb), named colors, hsl(), lab(), lch(), etc.
// Returns 1 on success, 0 on parse error
// Examples:
//   "oklch(0.623 0.214 259.815)"
//   "#ff0000"
//   "rgb(255 0 0)"
//   "rgba(255, 0, 0, 0.5)"
//   "hsl(120 100% 50%)"
//   "red"
unsigned char mcore_color_parse(const unsigned char* css_str, size_t len, mcore_color_t* out);

// Interpolate between two colors using perceptually-correct Oklab space
// This produces much better gradients than naive RGB interpolation
// t should be in range [0.0, 1.0]
void mcore_color_lerp(const mcore_color_t* a, const mcore_color_t* b, float t, mcore_color_t* out);

// Convert from RGBA8 (0-255) to mcore_color_t (0.0-1.0)
void mcore_color_from_rgba8(unsigned char r, unsigned char g, unsigned char b, unsigned char a, mcore_color_t* out);

#ifdef __cplusplus
}
#endif
