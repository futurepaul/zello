use parking_lot::Mutex;
use peniko::{Blob, Color, FontData};
use std::ffi::{c_void, CStr};
use std::sync::Arc;
use vello::Scene;

// Import color types for CSS parsing and interpolation
use peniko::color::{AlphaColor, Srgb, Oklab, DynamicColor};

mod gfx;
mod text;
mod text_input;
mod a11y;
mod image;

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}
fn set_err(e: impl std::fmt::Display) {
    LAST_ERROR.with(|s| *s.borrow_mut() = Some(e.to_string()));
}
#[no_mangle]
pub extern "C" fn mcore_last_error() -> *const i8 {
    use std::ffi::CString;
    LAST_ERROR.with(|s| {
        if let Some(msg) = s.borrow().as_ref() {
            // leak a CString for debugging simplicity (process lifetime)
            let c = CString::new(msg.clone()).unwrap();
            Box::leak(c.into_boxed_c_str()).as_ptr()
        } else {
            std::ptr::null()
        }
    })
}

#[repr(C)]
pub enum McorePlatform {
    MacOS = 1,
    Windows = 2,
    X11 = 3,
    Wayland = 4,
    IOS = 5,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreMacSurface {
    pub ns_view: *mut c_void,        // NSView*
    pub ca_metal_layer: *mut c_void, // CAMetalLayer*
    pub scale_factor: f32,
    pub width_px: i32,
    pub height_px: i32,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub union McoreSurfaceUnion {
    pub macos: McoreMacSurface,
}

#[repr(C)]
pub struct McoreSurfaceDesc {
    pub platform: McorePlatform,
    pub u: McoreSurfaceUnion,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreRgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreRoundedRect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub radius: f32,
    pub fill: McoreRgba,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreFontBlob {
    pub data: *const u8,
    pub len: usize,
    pub name: *const i8,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreTextReq {
    pub utf8: *const i8,
    pub wrap_width: f32,
    pub font_size_px: f32,
    pub font_id: i32,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreTextMetrics {
    pub advance_w: f32,
    pub advance_h: f32,
    pub line_count: i32,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreTextSize {
    pub width: f32,
    pub height: f32,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreTextStats {
    pub total_measure_calls: u32,
    pub total_offset_calls: u32,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreDrawCommand {
    pub kind: u8,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub radius: f32,
    pub color: [f32; 4],
    pub text_ptr: *const i8,
    pub font_size: f32,
    pub wrap_width: f32,
    pub font_id: i32,

    // Border fields
    pub border_width: f32,
    pub border_color: [f32; 4],
    pub has_border: u8,

    // Shadow fields
    pub shadow_offset_x: f32,
    pub shadow_offset_y: f32,
    pub shadow_blur: f32,
    pub shadow_color: [f32; 4],
    pub has_shadow: u8,

    pub _padding: [u8; 2],
}

// ============================================================================
// Color Support (using color crate for proper color handling)
// ============================================================================

/// Color type - just an RGBA tuple
/// Same layout as peniko::Color which is an array [r, g, b, a]
#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub struct McoreColor {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl From<McoreColor> for Color {
    fn from(c: McoreColor) -> Self {
        Color::new([c.r, c.g, c.b, c.a])
    }
}

impl From<Color> for McoreColor {
    fn from(c: Color) -> Self {
        Self { r: c.components[0], g: c.components[1], b: c.components[2], a: c.components[3] }
    }
}


/// Text measurement statistics for instrumentation
#[derive(Default)]
struct TextMeasurementStats {
    total_measure_calls: u32,
    total_offset_calls: u32,
}

impl TextMeasurementStats {
    fn reset(&mut self) {
        self.total_measure_calls = 0;
        self.total_offset_calls = 0;
    }
}

struct Engine {
    gfx: gfx::Gfx,
    scene: Scene,
    time_s: f64,
    text_cx: text::TextContext,
    fonts: Vec<(Vec<u8>, FontData)>,
    text_inputs: text_input::TextInputManager,
    a11y: Option<a11y::AccessibilityAdapter>,
    images: image::ImageManager,
    text_stats: TextMeasurementStats,
}

#[repr(C)]
pub enum McoreStatus {
    Ok = 0,
    Err = 1,
}

#[repr(C)]
pub struct McoreContext(Arc<Mutex<Engine>>);

#[no_mangle]
pub extern "C" fn mcore_create(desc: *const McoreSurfaceDesc) -> *mut McoreContext {
    let desc = unsafe { desc.as_ref() }.unwrap();
    match desc.platform {
        McorePlatform::MacOS | McorePlatform::IOS => {
            let mac = unsafe { desc.u.macos };
            // Convert to gfx::MacSurface (same for iOS)
            let mac_surface = gfx::MacSurface {
                ns_view: mac.ns_view,
                ca_metal_layer: mac.ca_metal_layer,
                scale_factor: mac.scale_factor,
                width_px: mac.width_px,
                height_px: mac.height_px,
            };
            // block_on in a new thread so we don't block AppKit/UIKit
            match pollster::block_on(gfx::Gfx::new_macos(&mac_surface)) {
                Ok(engine) => {
                    let eng = Engine {
                        gfx: engine,
                        scene: Scene::new(),
                        time_s: 0.0,
                        text_cx: text::TextContext::default(),
                        fonts: Vec::new(),
                        text_inputs: text_input::TextInputManager::new(),
                        a11y: None,
                        images: image::ImageManager::new(),
                        text_stats: TextMeasurementStats::default(),
                    };
                    Box::into_raw(Box::new(McoreContext(Arc::new(Mutex::new(eng)))))
                }
                Err(e) => {
                    set_err(e);
                    std::ptr::null_mut()
                }
            }
        }
        _ => {
            set_err("unsupported platform");
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn mcore_destroy(ctx: *mut McoreContext) {
    if !ctx.is_null() {
        unsafe { drop(Box::from_raw(ctx)) }
    }
}

#[no_mangle]
pub extern "C" fn mcore_resize(ctx: *mut McoreContext, desc: *const McoreSurfaceDesc) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let desc = unsafe { desc.as_ref() }.unwrap();
    match desc.platform {
        McorePlatform::MacOS | McorePlatform::IOS => {
            let mac = unsafe { desc.u.macos };
            let mac_surface = gfx::MacSurface {
                ns_view: mac.ns_view,
                ca_metal_layer: mac.ca_metal_layer,
                scale_factor: mac.scale_factor,
                width_px: mac.width_px,
                height_px: mac.height_px,
            };
            let mut guard = ctx.0.lock();
            let _ = guard.gfx.resize(&mac_surface);
        }
        _ => {}
    }
}

#[no_mangle]
pub extern "C" fn mcore_begin_frame(ctx: *mut McoreContext, time_seconds: f64) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();
    guard.time_s = time_seconds;
    guard.scene.reset();
}

#[no_mangle]
pub extern "C" fn mcore_rect_rounded(ctx: *mut McoreContext, rect: *const McoreRoundedRect) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let rect = unsafe { rect.as_ref() }.unwrap();
    let mut guard = ctx.0.lock();

    let shape = peniko::kurbo::RoundedRect::new(
        rect.x as f64,
        rect.y as f64,
        (rect.x + rect.w) as f64,
        (rect.y + rect.h) as f64,
        rect.radius as f64,
    );

    let color = Color::new([
        rect.fill.r,
        rect.fill.g,
        rect.fill.b,
        rect.fill.a,
    ]);

    guard.scene.fill(
        vello::peniko::Fill::NonZero,
        peniko::kurbo::Affine::IDENTITY,
        color,
        None,
        &shape,
    );
}

#[no_mangle]
pub extern "C" fn mcore_font_register(ctx: *mut McoreContext, blob: *const McoreFontBlob) -> i32 {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let blob = unsafe { blob.as_ref() }.unwrap();
    let mut guard = ctx.0.lock();

    let data = unsafe { std::slice::from_raw_parts(blob.data, blob.len) };
    let font_data_vec = data.to_vec();

    let font_blob = Blob::new(Arc::new(font_data_vec.clone()));
    let font_data = FontData::new(font_blob.clone(), 0);

    guard.text_cx.font_cx.collection.register_fonts(font_blob, None);
    guard.fonts.push((font_data_vec, font_data));

    (guard.fonts.len() - 1) as i32
}

#[no_mangle]
pub extern "C" fn mcore_text_layout(
    ctx: *mut McoreContext,
    req: *const McoreTextReq,
    out: *mut McoreTextMetrics,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let req = unsafe { req.as_ref() }.unwrap();
    let out = unsafe { out.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();

    let text = unsafe { CStr::from_ptr(req.utf8) }.to_str().unwrap_or("");
    let scale = guard.gfx.scale();

    let metrics = text::layout_text(
        &mut guard.text_cx,
        text,
        req.font_size_px,
        req.wrap_width,
        scale,
    );

    out.advance_w = metrics.width;
    out.advance_h = metrics.height;
    out.line_count = metrics.line_count as i32;
}

#[no_mangle]
pub extern "C" fn mcore_measure_text(
    ctx: *mut McoreContext,
    text: *const i8,
    font_size: f32,
    max_width: f32,
    out: *mut McoreTextSize,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let text = unsafe { CStr::from_ptr(text) }.to_str().unwrap_or("");
    let out = unsafe { out.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();

    // Increment instrumentation counter
    guard.text_stats.total_measure_calls += 1;

    let scale = guard.gfx.scale();

    // Measure with scale for quality, returns logical measurements
    let (width, height) = text::measure_text(
        &mut guard.text_cx,
        text,
        font_size,
        max_width,
        scale,
    );

    out.width = width;
    out.height = height;
}

#[no_mangle]
pub extern "C" fn mcore_measure_text_to_byte_offset(
    ctx: *mut McoreContext,
    text: *const i8,
    font_size: f32,
    byte_offset: i32,
) -> f32 {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let text = unsafe { CStr::from_ptr(text) }.to_str().unwrap_or("");
    let mut guard = ctx.0.lock();

    // Increment instrumentation counter
    guard.text_stats.total_offset_calls += 1;

    let scale = guard.gfx.scale();
    let byte_offset = byte_offset.max(0) as usize;

    text::byte_offset_to_x(
        &mut guard.text_cx,
        text,
        font_size,
        byte_offset,
        scale,
    )
}

#[no_mangle]
pub extern "C" fn mcore_get_text_stats(
    ctx: *mut McoreContext,
    out: *mut McoreTextStats,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let out = unsafe { out.as_mut() }.unwrap();
    let guard = ctx.0.lock();

    out.total_measure_calls = guard.text_stats.total_measure_calls;
    out.total_offset_calls = guard.text_stats.total_offset_calls;
}

#[no_mangle]
pub extern "C" fn mcore_reset_text_stats(ctx: *mut McoreContext) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();
    guard.text_stats.reset();
}

#[no_mangle]
pub extern "C" fn mcore_text_draw(
    ctx: *mut McoreContext,
    req: *const McoreTextReq,
    x: f32,
    y: f32,
    color: McoreRgba,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let req = unsafe { req.as_ref() }.unwrap();
    let mut guard = ctx.0.lock();

    let text = unsafe { CStr::from_ptr(req.utf8) }.to_str().unwrap_or("");
    let scale = guard.gfx.scale();
    let color_val = Color::new([color.r, color.g, color.b, color.a]);

    // Use raw pointers to split borrows
    let scene_ptr = &mut guard.scene as *mut Scene;
    let text_cx_ptr = &mut guard.text_cx as *mut text::TextContext;

    unsafe {
        text::draw_text(
            &mut *scene_ptr,
            &mut *text_cx_ptr,
            text,
            x,
            y,
            req.font_size_px,
            req.wrap_width,
            color_val,
            scale,
        );
    }
}

#[no_mangle]
pub extern "C" fn mcore_push_clip_rect(
    ctx: *mut McoreContext,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();

    // Push a clip layer with the specified rectangle
    let clip_rect = peniko::kurbo::Rect::new(x as f64, y as f64, (x + width) as f64, (y + height) as f64);
    guard.scene.push_layer(vello::peniko::BlendMode::default(), 1.0, peniko::kurbo::Affine::IDENTITY, &clip_rect);
}

#[no_mangle]
pub extern "C" fn mcore_pop_clip(ctx: *mut McoreContext) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();
    guard.scene.pop_layer();
}

#[no_mangle]
pub extern "C" fn mcore_render_commands(
    ctx: *mut McoreContext,
    commands: *const McoreDrawCommand,
    count: i32,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let commands = unsafe { std::slice::from_raw_parts(commands, count as usize) };
    let mut guard = ctx.0.lock();

    // Commands are in physical pixels, but text rendering needs scale for rasterization quality
    let scale = guard.gfx.scale();

    // Use raw pointers to split borrows for text rendering
    let scene_ptr = &mut guard.scene as *mut Scene;
    let text_cx_ptr = &mut guard.text_cx as *mut text::TextContext;

    for cmd in commands {
        match cmd.kind {
            0 => {
                // RoundedRect - scale from logical to physical pixels
                let shape = peniko::kurbo::RoundedRect::new(
                    (cmd.x * scale) as f64,
                    (cmd.y * scale) as f64,
                    ((cmd.x + cmd.width) * scale) as f64,
                    ((cmd.y + cmd.height) * scale) as f64,
                    (cmd.radius * scale) as f64,
                );
                let color = Color::new([cmd.color[0], cmd.color[1], cmd.color[2], cmd.color[3]]);
                unsafe {
                    (*scene_ptr).fill(vello::peniko::Fill::NonZero, peniko::kurbo::Affine::IDENTITY, color, None, &shape);
                }
            }
            1 => {
                // Text - scale from logical to physical pixels
                let text = unsafe { CStr::from_ptr(cmd.text_ptr) }.to_str().unwrap_or("");
                let color = Color::new([cmd.color[0], cmd.color[1], cmd.color[2], cmd.color[3]]);

                unsafe {
                    text::draw_text(
                        &mut *scene_ptr,
                        &mut *text_cx_ptr,
                        text,
                        cmd.x * scale,
                        cmd.y * scale,
                        cmd.font_size,
                        cmd.wrap_width,
                        color,
                        scale,
                    );
                }
            }
            2 => {
                // PushClip - scale from logical to physical pixels
                let clip_rect = peniko::kurbo::Rect::new(
                    (cmd.x * scale) as f64,
                    (cmd.y * scale) as f64,
                    ((cmd.x + cmd.width) * scale) as f64,
                    ((cmd.y + cmd.height) * scale) as f64,
                );
                unsafe {
                    (*scene_ptr).push_layer(vello::peniko::BlendMode::default(), 1.0, peniko::kurbo::Affine::IDENTITY, &clip_rect);
                }
            }
            3 => {
                // PopClip
                unsafe {
                    (*scene_ptr).pop_layer();
                }
            }
            4 => {
                // StyledRect (with optional border and shadow) - scale from logical to physical pixels
                let shape = peniko::kurbo::RoundedRect::new(
                    (cmd.x * scale) as f64,
                    (cmd.y * scale) as f64,
                    ((cmd.x + cmd.width) * scale) as f64,
                    ((cmd.y + cmd.height) * scale) as f64,
                    (cmd.radius * scale) as f64,
                );

                unsafe {
                    // 1. Draw shadow if present (using Vello's blurred rect)
                    if cmd.has_shadow != 0 {
                        let shadow_rect = peniko::kurbo::Rect::new(
                            ((cmd.x + cmd.shadow_offset_x) * scale) as f64,
                            ((cmd.y + cmd.shadow_offset_y) * scale) as f64,
                            ((cmd.x + cmd.width + cmd.shadow_offset_x) * scale) as f64,
                            ((cmd.y + cmd.height + cmd.shadow_offset_y) * scale) as f64,
                        );
                        let shadow_color = Color::new([
                            cmd.shadow_color[0],
                            cmd.shadow_color[1],
                            cmd.shadow_color[2],
                            cmd.shadow_color[3],
                        ]);

                        // Use draw_blurred_rounded_rect for drop shadow effect
                        // Signature: (transform, rect, color, blur_radius, corner_radius)
                        (*scene_ptr).draw_blurred_rounded_rect(
                            peniko::kurbo::Affine::IDENTITY,
                            shadow_rect,
                            shadow_color,
                            (cmd.shadow_blur * scale) as f64,
                            (cmd.radius * scale) as f64,
                        );
                    }

                    // 2. Draw fill
                    let fill_color = Color::new([cmd.color[0], cmd.color[1], cmd.color[2], cmd.color[3]]);
                    (*scene_ptr).fill(
                        vello::peniko::Fill::NonZero,
                        peniko::kurbo::Affine::IDENTITY,
                        fill_color,
                        None,
                        &shape,
                    );

                    // 3. Draw border if present (using stroke)
                    if cmd.has_border != 0 && cmd.border_width > 0.0 {
                        let border_color = Color::new([
                            cmd.border_color[0],
                            cmd.border_color[1],
                            cmd.border_color[2],
                            cmd.border_color[3],
                        ]);
                        let stroke = peniko::kurbo::Stroke::new((cmd.border_width * scale) as f64);
                        (*scene_ptr).stroke(
                            &stroke,
                            peniko::kurbo::Affine::IDENTITY,
                            border_color,
                            None,
                            &shape,
                        );
                    }
                }
            }
            _ => {}
        }
    }
}

#[no_mangle]
pub extern "C" fn mcore_end_frame_present(ctx: *mut McoreContext, clear: McoreRgba) -> McoreStatus {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();

    let clear_color = Color::new([clear.r, clear.g, clear.b, clear.a]);

    // Clone the scene to avoid borrow conflict
    let scene = guard.scene.clone();

    match guard.gfx.render_scene(&scene, clear_color) {
        Ok(_) => McoreStatus::Ok,
        Err(e) => {
            set_err(e);
            McoreStatus::Err
        }
    }
}

// ============================================================================
// Text Input FFI
// ============================================================================

#[repr(C)]
#[derive(Copy, Clone)]
pub enum McoreTextEventKind {
    InsertChar = 0,
    Backspace = 1,
    Delete = 2,
    MoveCursor = 3,
    SetCursor = 4,
    InsertText = 5,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub enum McoreCursorDirection {
    Left = 0,
    Right = 1,
    Home = 2,
    End = 3,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreTextEvent {
    pub kind: McoreTextEventKind,
    pub char_code: u32,
    pub direction: McoreCursorDirection,
    pub extend_selection: u8,
    pub cursor_position: i32,
    pub text_ptr: *const i8,
}

/// Handle a text input event for a specific widget ID
/// Returns true if the text changed
#[no_mangle]
pub extern "C" fn mcore_text_input_event(
    ctx: *mut McoreContext,
    id: u64,
    event: *const McoreTextEvent,
) -> u8 {
    let ctx = unsafe { ctx.as_mut() };
    let event = unsafe { event.as_ref() };

    if ctx.is_none() || event.is_none() {
        return 0;
    }

    let ctx = ctx.unwrap();
    let event = event.unwrap();
    let mut guard = ctx.0.lock();

    let state = guard.text_inputs.get_or_create(id);

    match event.kind {
        McoreTextEventKind::InsertChar => {
            if let Some(ch) = char::from_u32(event.char_code) {
                state.insert_char(ch);
                return 1;
            }
        }
        McoreTextEventKind::Backspace => {
            state.backspace();
            return 1;
        }
        McoreTextEventKind::Delete => {
            state.delete();
            return 1;
        }
        McoreTextEventKind::MoveCursor => {
            match event.direction {
                McoreCursorDirection::Left => state.move_cursor_left(),
                McoreCursorDirection::Right => state.move_cursor_right(),
                McoreCursorDirection::Home => state.move_cursor_home(),
                McoreCursorDirection::End => state.move_cursor_end(),
            }
            return 0;  // Cursor movement doesn't change text
        }
        McoreTextEventKind::SetCursor => {
            state.set_cursor(event.cursor_position.max(0) as usize);
            return 0;  // Cursor movement doesn't change text
        }
        McoreTextEventKind::InsertText => {
            if !event.text_ptr.is_null() {
                let text = unsafe { CStr::from_ptr(event.text_ptr) }
                    .to_str()
                    .unwrap_or("");
                state.insert_text(text);
                return 1;
            }
        }
    }

    0
}

/// Get the current text content for a widget ID
/// Returns the number of bytes written (excluding null terminator)
#[no_mangle]
pub extern "C" fn mcore_text_input_get(
    ctx: *mut McoreContext,
    id: u64,
    buf: *mut u8,
    buf_len: i32,
) -> i32 {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || buf.is_null() || buf_len <= 0 {
        return 0;
    }

    let ctx = ctx.unwrap();
    let guard = ctx.0.lock();

    if let Some(state) = guard.text_inputs.get(id) {
        let content_bytes = state.content.as_bytes();
        let copy_len = content_bytes.len().min((buf_len - 1) as usize);

        unsafe {
            std::ptr::copy_nonoverlapping(content_bytes.as_ptr(), buf, copy_len);
            *buf.add(copy_len) = 0;  // Null terminate
        }

        copy_len as i32
    } else {
        // No state yet, return empty string
        unsafe {
            *buf = 0;
        }
        0
    }
}

/// Get the cursor position (byte offset) for a widget ID
#[no_mangle]
pub extern "C" fn mcore_text_input_cursor(
    ctx: *mut McoreContext,
    id: u64,
) -> i32 {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() {
        return 0;
    }

    let ctx = ctx.unwrap();
    let guard = ctx.0.lock();

    guard.text_inputs
        .get(id)
        .map(|s| s.cursor as i32)
        .unwrap_or(0)
}

/// Set the text content for a widget ID
#[no_mangle]
pub extern "C" fn mcore_text_input_set(
    ctx: *mut McoreContext,
    id: u64,
    text: *const i8,
) {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || text.is_null() {
        return;
    }

    let ctx = ctx.unwrap();
    let text_str = unsafe { CStr::from_ptr(text) }
        .to_str()
        .unwrap_or("");

    let mut guard = ctx.0.lock();
    let state = guard.text_inputs.get_or_create(id);
    state.set_text(text_str);
}

/// Get selection range for a text input widget
/// Returns true if there is a selection, and fills out_start and out_end with the byte offsets
#[no_mangle]
pub extern "C" fn mcore_text_input_get_selection(
    ctx: *mut McoreContext,
    id: u64,
    out_start: *mut i32,
    out_end: *mut i32,
) -> u8 {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || out_start.is_null() || out_end.is_null() {
        return 0;
    }

    let ctx = ctx.unwrap();
    let guard = ctx.0.lock();

    if let Some(state) = guard.text_inputs.get(id) {
        if let Some(sel) = state.get_selection() {
            unsafe {
                *out_start = sel.start as i32;
                *out_end = sel.end as i32;
            }
            return 1;
        }
    }

    0
}

/// Set cursor position and optionally start a selection
#[no_mangle]
pub extern "C" fn mcore_text_input_set_cursor_pos(
    ctx: *mut McoreContext,
    id: u64,
    byte_offset: i32,
    extend_selection: u8,
) {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || byte_offset < 0 {
        return;
    }

    let ctx = ctx.unwrap();
    let mut guard = ctx.0.lock();
    let state = guard.text_inputs.get_or_create(id);

    if extend_selection != 0 {
        // Extend or create selection
        state.extend_selection_to(byte_offset as usize);
    } else {
        // Just move cursor, clear selection AND anchor
        state.set_cursor(byte_offset as usize);
        state.clear_selection();
        state.selection_anchor = None;
    }
}

/// Get the selected text (returns length, copies into buffer)
#[no_mangle]
pub extern "C" fn mcore_text_input_get_selected_text(
    ctx: *mut McoreContext,
    id: u64,
    buf: *mut i8,
    buf_len: i32,
) -> i32 {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || buf.is_null() || buf_len <= 0 {
        eprintln!("get_selected_text: early return (null check)");
        return 0;
    }

    let ctx = ctx.unwrap();
    let guard = ctx.0.lock();

    eprintln!("get_selected_text: id={}", id);

    if let Some(state) = guard.text_inputs.get(id) {
        eprintln!("  Found state: cursor={}, anchor={:?}, selection={:?}",
            state.cursor, state.selection_anchor, state.selection);

        if let Some(selected) = state.get_selection_text() {
            let bytes = selected.as_bytes();
            let copy_len = bytes.len().min((buf_len - 1) as usize);
            eprintln!("  Copying {} bytes: {:?}", copy_len, selected);
            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, copy_len);
                *buf.add(copy_len) = 0; // Null terminate
            }
            return copy_len as i32;
        } else {
            eprintln!("  No selection text");
        }
    } else {
        eprintln!("  State not found for id={}", id);
    }

    0
}

/// Start a selection at a specific position (for mouse down)
/// Sets both cursor and anchor to the same position, clearing any existing selection
#[no_mangle]
pub extern "C" fn mcore_text_input_start_selection(
    ctx: *mut McoreContext,
    id: u64,
    byte_offset: i32,
) {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || byte_offset < 0 {
        return;
    }

    let ctx = ctx.unwrap();
    let mut guard = ctx.0.lock();
    let state = guard.text_inputs.get_or_create(id);

    eprintln!("start_selection: id={}, byte_offset={}", id, byte_offset);

    // Set cursor and anchor to the same position, clear selection
    state.set_cursor(byte_offset as usize);
    state.selection_anchor = Some(byte_offset as usize);
    state.selection = None;

    eprintln!("  cursor={}, anchor={:?}, selection={:?}", state.cursor, state.selection_anchor, state.selection);
}

// ========== IME (Input Method Editor) Support ==========

#[repr(C)]
pub struct McoreImePreedit {
    pub text: *const i8,
    pub cursor_offset: i32,
}

/// Set IME preedit (composition) text for a text input
#[no_mangle]
pub extern "C" fn mcore_ime_set_preedit(
    ctx: *mut McoreContext,
    id: u64,
    preedit: *const McoreImePreedit,
) {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || preedit.is_null() {
        return;
    }

    let ctx = ctx.unwrap();
    let preedit = unsafe { preedit.as_ref() }.unwrap();

    let text = if preedit.text.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(preedit.text) }
            .to_str()
            .unwrap_or("")
    };

    let mut guard = ctx.0.lock();
    let state = guard.text_inputs.get_or_create(id);

    if text.is_empty() {
        // Clear preedit
        state.ime_composition = None;
    } else {
        // Set preedit
        state.ime_composition = Some(crate::text_input::ImeComposition {
            text: text.to_string(),
            cursor_offset: preedit.cursor_offset.max(0) as usize,
        });
    }
}

/// Commit IME text (finalize composition)
#[no_mangle]
pub extern "C" fn mcore_ime_commit(
    ctx: *mut McoreContext,
    id: u64,
    text: *const i8,
) {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || text.is_null() {
        return;
    }

    let ctx = ctx.unwrap();
    let text_str = unsafe { CStr::from_ptr(text) }
        .to_str()
        .unwrap_or("");

    let mut guard = ctx.0.lock();
    let state = guard.text_inputs.get_or_create(id);

    // Clear any existing preedit
    state.ime_composition = None;

    // Insert the committed text
    state.insert_text(text_str);
}

/// Clear IME preedit state
#[no_mangle]
pub extern "C" fn mcore_ime_clear_preedit(
    ctx: *mut McoreContext,
    id: u64,
) {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() {
        return;
    }

    let ctx = ctx.unwrap();
    let mut guard = ctx.0.lock();

    if let Some(state) = guard.text_inputs.get_mut(id) {
        state.ime_composition = None;
    }
}

/// Get IME preedit text if any
/// Returns 1 if there is preedit text, 0 otherwise
#[no_mangle]
pub extern "C" fn mcore_ime_get_preedit(
    ctx: *mut McoreContext,
    id: u64,
    buf: *mut i8,
    buf_len: i32,
    out_cursor_offset: *mut i32,
) -> u8 {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || buf.is_null() || buf_len <= 0 {
        return 0;
    }

    let ctx = ctx.unwrap();
    let guard = ctx.0.lock();

    if let Some(state) = guard.text_inputs.get(id) {
        if let Some(composition) = &state.ime_composition {
            let bytes = composition.text.as_bytes();
            let copy_len = bytes.len().min((buf_len - 1) as usize);

            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, copy_len);
                *buf.add(copy_len) = 0; // Null terminate

                if !out_cursor_offset.is_null() {
                    *out_cursor_offset = composition.cursor_offset as i32;
                }
            }

            return 1;
        }
    }

    // No preedit text
    if !buf.is_null() && buf_len > 0 {
        unsafe {
            *buf = 0; // Null terminate empty string
        }
    }

    0
}

// ============================================================================
// Accessibility (AccessKit) FFI
// ============================================================================

/// Initialize the accessibility adapter for a given NSView
/// This should be called after creating the window but before showing it
///
/// # Safety
/// ns_view must be a valid pointer to an NSView instance
#[no_mangle]
pub extern "C" fn mcore_a11y_init(
    ctx: *mut McoreContext,
    ns_view: *mut c_void,
) {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || ns_view.is_null() {
        return;
    }

    let ctx = ctx.unwrap();
    let mut guard = ctx.0.lock();

    // Create the accessibility adapter
    unsafe {
        guard.a11y = Some(a11y::AccessibilityAdapter::new(ns_view));
    }
}

/// Represents a single accessibility node sent from Zig
#[repr(C)]
pub struct McoreA11yNode {
    pub id: u64,
    pub role: u8,  // Maps to accesskit::Role
    pub label: *const i8,
    pub bounds: McoreRect,
    pub actions: u32,  // Bitfield of supported actions
    pub children: *const u64,
    pub children_count: i32,
    pub value: *const i8,
    pub text_selection_start: i32,
    pub text_selection_end: i32,
}

#[repr(C)]
pub struct McoreRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// Update the accessibility tree
/// Zig builds an array of nodes and sends them all at once
#[no_mangle]
pub extern "C" fn mcore_a11y_update(
    ctx: *mut McoreContext,
    nodes: *const McoreA11yNode,
    node_count: i32,
    root_id: u64,
    focus_id: u64,
) {
    use accesskit::{Action, NodeId, Node, Role, Rect, Tree, TreeUpdate};

    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || nodes.is_null() || node_count <= 0 {
        return;
    }

    let ctx = ctx.unwrap();
    let guard = ctx.0.lock();

    // Convert C nodes to AccessKit nodes
    let nodes_slice = unsafe { std::slice::from_raw_parts(nodes, node_count as usize) };

    let mut ak_nodes = Vec::new();

    for c_node in nodes_slice {
        let node_id = NodeId(c_node.id);

        // Map role
        let role = match c_node.role {
            0 => Role::Window,
            1 => Role::Button,
            2 => Role::TextInput,
            3 => Role::Label,
            4 => Role::Group,
            _ => Role::Unknown,
        };

        let mut node = Node::new(role);

        // Set label
        if !c_node.label.is_null() {
            let label = unsafe { CStr::from_ptr(c_node.label) }
                .to_str()
                .unwrap_or("");
            if !label.is_empty() {
                node.set_label(label.to_string());
            }
        }

        // Set value (for text inputs)
        if !c_node.value.is_null() {
            let value = unsafe { CStr::from_ptr(c_node.value) }
                .to_str()
                .unwrap_or("");
            if !value.is_empty() {
                node.set_value(value.to_string());
            }
        }

        // Set bounds
        node.set_bounds(Rect {
            x0: c_node.bounds.x as f64,
            y0: c_node.bounds.y as f64,
            x1: (c_node.bounds.x + c_node.bounds.width) as f64,
            y1: (c_node.bounds.y + c_node.bounds.height) as f64,
        });

        // Set children
        if !c_node.children.is_null() && c_node.children_count > 0 {
            let children = unsafe {
                std::slice::from_raw_parts(c_node.children, c_node.children_count as usize)
            };
            let child_ids: Vec<NodeId> = children.iter().map(|&id| NodeId(id)).collect();
            node.set_children(child_ids);
        }

        // Set actions (bitfield)
        if c_node.actions & 0x01 != 0 {  // Focus
            node.add_action(Action::Focus);
        }
        if c_node.actions & 0x02 != 0 {  // Click
            node.add_action(Action::Click);
        }

        // TODO: Set text selection for text inputs
        // Text selection in AccessKit is more complex than just byte offsets
        // It requires TextPosition with node IDs and character indices
        // We'll implement this properly later when we have text run nodes
        let _ = (c_node.text_selection_start, c_node.text_selection_end);

        ak_nodes.push((node_id, node));
    }

    // Build the tree update
    let tree_update = TreeUpdate {
        nodes: ak_nodes,
        tree: Some(Tree::new(NodeId(root_id))),
        focus: NodeId(focus_id),
    };

    // Send to adapter
    if let Some(a11y) = &guard.a11y {
        a11y.update_tree(tree_update);
    }
}

/// Set callback for accessibility actions (focus, click, etc.)
#[no_mangle]
pub extern "C" fn mcore_a11y_set_action_callback(
    callback: extern "C" fn(u64, u8),
) {
    a11y::set_action_callback(callback);
}

// ============================================================================
// Color Functions
// ============================================================================

/// Parse a CSS color string into McoreColor
/// Supports: oklch(), rgb(), rgba(), hex (#rrggbb), named colors, hsl(), lab(), lch(), etc.
/// Returns 1 on success, 0 on parse error
#[no_mangle]
pub extern "C" fn mcore_color_parse(
    css_str: *const u8,
    len: usize,
    out: *mut McoreColor,
) -> u8 {
    let css_bytes = unsafe { std::slice::from_raw_parts(css_str, len) };
    let css_str = match std::str::from_utf8(css_bytes) {
        Ok(s) => s,
        Err(_) => return 0,
    };

    // Parse using color crate's CSS parser
    let parsed: DynamicColor = match css_str.parse() {
        Ok(c) => c,
        Err(_) => return 0,
    };

    // Convert to sRGB as AlphaColor
    let srgb: AlphaColor<Srgb> = parsed.to_alpha_color();

    // Extract components
    unsafe {
        (*out).r = srgb.components[0];
        (*out).g = srgb.components[1];
        (*out).b = srgb.components[2];
        (*out).a = srgb.components[3];
    }
    1
}

/// Interpolate between two colors using perceptually-correct Oklab space
/// This produces much better results than naive RGB interpolation
#[no_mangle]
pub extern "C" fn mcore_color_lerp(
    a: *const McoreColor,
    b: *const McoreColor,
    t: f32,
    out: *mut McoreColor,
) {
    let a = unsafe { &*a };
    let b = unsafe { &*b };

    // Create AlphaColor<Srgb> from components
    let a_srgb = AlphaColor::<Srgb> {
        components: [a.r, a.g, a.b, a.a],
        cs: std::marker::PhantomData,
    };
    let b_srgb = AlphaColor::<Srgb> {
        components: [b.r, b.g, b.b, b.a],
        cs: std::marker::PhantomData,
    };

    // Convert to Oklab for perceptually-correct interpolation
    let a_oklab: AlphaColor<Oklab> = a_srgb.convert();
    let b_oklab: AlphaColor<Oklab> = b_srgb.convert();

    // Lerp in Oklab space (rectangular interpolation)
    let result = a_oklab.lerp_rect(b_oklab, t);

    // Convert back to sRGB
    let result_srgb: AlphaColor<Srgb> = result.convert();

    unsafe {
        (*out).r = result_srgb.components[0];
        (*out).g = result_srgb.components[1];
        (*out).b = result_srgb.components[2];
        (*out).a = result_srgb.components[3];
    }
}

/// Convert from RGBA8 (0-255) to McoreColor (0.0-1.0)
#[no_mangle]
pub extern "C" fn mcore_color_from_rgba8(
    r: u8,
    g: u8,
    b: u8,
    a: u8,
    out: *mut McoreColor,
) {
    unsafe {
        (*out).r = r as f32 / 255.0;
        (*out).g = g as f32 / 255.0;
        (*out).b = b as f32 / 255.0;
        (*out).a = a as f32 / 255.0;
    }
}

// ============================================================================
// Image Management FFI
// ============================================================================

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreImageDesc {
    pub data: *const u8,
    pub data_len: u32,
    pub width: u32,
    pub height: u32,
    pub format: u8,
    pub alpha_type: u8,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreImageTransform {
    pub x: f32,
    pub y: f32,
    pub scale: f32,
    pub rotation_deg: f32,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreImageInfo {
    pub image_id: i32,
    pub width: u32,
    pub height: u32,
}

/// Register an image and copy pixel data to Rust
/// Returns an image ID (>= 0) or -1 on error
/// The `data` pointer can be freed after this function returns
#[no_mangle]
pub extern "C" fn mcore_image_register(
    ctx: *mut McoreContext,
    desc: *const McoreImageDesc,
) -> i32 {
    let ctx = unsafe { ctx.as_mut() };
    let desc = unsafe { desc.as_ref() };

    if ctx.is_none() || desc.is_none() {
        set_err("Null pointer passed to mcore_image_register");
        return -1;
    }

    let ctx = ctx.unwrap();
    let desc = desc.unwrap();
    let mut guard = ctx.0.lock();

    // Copy pixel data from Zig memory
    let pixels = unsafe {
        std::slice::from_raw_parts(desc.data, desc.data_len as usize)
    };

    // Map format enum (only RGBA8 supported for now)
    let format = match desc.format {
        1 => vello::peniko::ImageFormat::Rgba8,
        _ => {
            set_err(format!("Unsupported image format: {} (only RGBA8 supported)", desc.format));
            return -1;
        }
    };

    // Map alpha type enum
    let alpha_type = match desc.alpha_type {
        2 => vello::peniko::ImageAlphaType::Alpha,
        _ => {
            set_err(format!("Unsupported alpha type: {} (only straight alpha supported)", desc.alpha_type));
            return -1;
        }
    };

    // Register image
    match guard.images.register(pixels, desc.width, desc.height, format, alpha_type) {
        Ok(id) => id,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// Increment reference count for an image
#[no_mangle]
pub extern "C" fn mcore_image_retain(
    ctx: *mut McoreContext,
    image_id: i32,
) {
    let ctx = unsafe { ctx.as_mut() };
    if ctx.is_none() {
        return;
    }

    let ctx = ctx.unwrap();
    let mut guard = ctx.0.lock();

    if let Err(e) = guard.images.retain(image_id) {
        set_err(e);
    }
}

/// Decrement reference count, free when 0
#[no_mangle]
pub extern "C" fn mcore_image_release(
    ctx: *mut McoreContext,
    image_id: i32,
) {
    let ctx = unsafe { ctx.as_mut() };
    if ctx.is_none() {
        return;
    }

    let ctx = ctx.unwrap();
    let mut guard = ctx.0.lock();

    if let Err(e) = guard.images.release(image_id) {
        set_err(e);
    }
}

/// Draw an image with transform
#[no_mangle]
pub extern "C" fn mcore_image_draw(
    ctx: *mut McoreContext,
    image_id: i32,
    transform: *const McoreImageTransform,
) {
    let ctx = unsafe { ctx.as_mut() };
    let transform = unsafe { transform.as_ref() };

    if ctx.is_none() || transform.is_none() {
        return;
    }

    let ctx = ctx.unwrap();
    let transform = transform.unwrap();
    let mut guard = ctx.0.lock();

    // Look up image
    if let Some(image_data) = guard.images.get(image_id) {
        // Build affine transform - scale position from logical to physical pixels
        use peniko::kurbo::Affine;
        let dpi_scale = guard.gfx.scale();

        let affine = Affine::scale(transform.scale as f64)
            .then_rotate((transform.rotation_deg as f64).to_radians())
            .then_translate(((transform.x * dpi_scale) as f64, (transform.y * dpi_scale) as f64).into());

        // Draw to scene (create ImageBrush from ImageData)
        let brush = peniko::ImageBrush::from(image_data.clone());
        guard.scene.draw_image(&brush, affine);
    }
}

/// Load and register an image from a file path (JPEG, PNG, etc.)
/// Returns image info (id, width, height). id is -1 on error.
#[no_mangle]
pub extern "C" fn mcore_image_load_file(
    ctx: *mut McoreContext,
    path: *const i8,
) -> McoreImageInfo {
    let ctx = unsafe { ctx.as_mut() };

    if ctx.is_none() || path.is_null() {
        set_err("Null pointer passed to mcore_image_load_file");
        return McoreImageInfo {
            image_id: -1,
            width: 0,
            height: 0,
        };
    }

    let ctx = ctx.unwrap();
    let path_str = unsafe { CStr::from_ptr(path) }
        .to_str()
        .unwrap_or("");

    let mut guard = ctx.0.lock();

    match guard.images.register_from_file(path_str) {
        Ok(id) => {
            // Get dimensions
            if let Some((width, height)) = guard.images.get_dimensions(id) {
                McoreImageInfo {
                    image_id: id,
                    width,
                    height,
                }
            } else {
                set_err("Failed to get image dimensions");
                McoreImageInfo {
                    image_id: -1,
                    width: 0,
                    height: 0,
                }
            }
        }
        Err(e) => {
            set_err(e);
            McoreImageInfo {
                image_id: -1,
                width: 0,
                height: 0,
            }
        }
    }
}

/// Get image dimensions by ID
/// Returns 1 on success, 0 if image not found
#[no_mangle]
pub extern "C" fn mcore_image_get_info(
    ctx: *mut McoreContext,
    image_id: i32,
    out: *mut McoreImageInfo,
) -> u8 {
    let ctx = unsafe { ctx.as_mut() };
    let out = unsafe { out.as_mut() };

    if ctx.is_none() || out.is_none() {
        return 0;
    }

    let ctx = ctx.unwrap();
    let out = out.unwrap();
    let guard = ctx.0.lock();

    if let Some((width, height)) = guard.images.get_dimensions(image_id) {
        out.image_id = image_id;
        out.width = width;
        out.height = height;
        1
    } else {
        0
    }
}
