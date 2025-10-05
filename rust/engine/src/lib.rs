use parking_lot::Mutex;
use parley::layout::{Alignment, Layout};
use parley::style::{FontFamily, FontStack, StyleProperty};
use parley::{FontContext, LayoutContext};
use peniko::{kurbo, Brush, Color};
use raw_window_handle::{AppKitDisplayHandle, AppKitWindowHandle, RawDisplayHandle, RawWindowHandle};
use std::ffi::{c_void, CStr};
use std::ptr::NonNull;
use std::sync::Arc;
use vello::{AaSupport, Renderer, RendererOptions, Scene};

#[derive(Debug, thiserror::Error)]
enum EngineError {
    #[error("wgpu error: {0}")]
    Wgpu(String),
    #[error("invalid surface")]
    InvalidSurface,
    #[error("vello error: {0}")]
    Vello(String),
}

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

struct Gfx {
    instance: wgpu::Instance,
    surface: wgpu::Surface<'static>,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    renderer: Renderer,
    size: (u32, u32),
    scale: f32,
}

impl Gfx {
    async fn new_macos(desc: &McoreMacSurface) -> Result<Self, EngineError> {
        // SAFETY: we trust the caller to pass a valid NSView* and CAMetalLayer*.
        // raw-window-handle only needs the NSView pointer populated.
        let ns_view = NonNull::new(desc.ns_view).ok_or(EngineError::InvalidSurface)?;
        let win = AppKitWindowHandle::new(ns_view);
        let win = RawWindowHandle::AppKit(win);

        let disp = RawDisplayHandle::AppKit(AppKitDisplayHandle::new());

        let instance = wgpu::Instance::default();
        // Unsafe: creating surface from raw handles is inherently unsafe.
        let surface = unsafe {
            instance
                .create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                    raw_display_handle: disp,
                    raw_window_handle: win,
                })
                .map_err(|e| EngineError::Wgpu(format!("{e:?}")))?
        };

        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
            .ok_or_else(|| EngineError::Wgpu("no adapter".into()))?;

        // Request device with higher limits for Vello
        let mut limits = wgpu::Limits::default();
        limits.max_storage_buffers_per_shader_stage = 8;

        let (device, queue) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("mcore-device"),
                    required_features: wgpu::Features::empty(),
                    required_limits: limits,
                },
                None,
            )
            .await
            .map_err(|e| EngineError::Wgpu(format!("{e:?}")))?;

        let (w, h) = (desc.width_px.max(1) as u32, desc.height_px.max(1) as u32);
        let caps = surface.get_capabilities(&adapter);
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| f.is_srgb())
            .unwrap_or(caps.formats[0]);

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: w,
            height: h,
            present_mode: wgpu::PresentMode::Fifo,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);

        // Create Vello renderer
        let renderer = Renderer::new(
            &device,
            RendererOptions {
                surface_format: Some(format),
                use_cpu: false,
                antialiasing_support: AaSupport::all(),
                num_init_threads: None,
            },
        )
        .map_err(|e| EngineError::Vello(format!("{e:?}")))?;

        Ok(Self {
            instance,
            surface,
            adapter,
            device,
            queue,
            config,
            renderer,
            size: (w, h),
            scale: desc.scale_factor,
        })
    }

    fn resize(&mut self, w: u32, h: u32, scale: f32) {
        if w == 0 || h == 0 {
            return;
        }
        self.size = (w, h);
        self.scale = scale;
        self.config.width = w;
        self.config.height = h;
        self.surface.configure(&self.device, &self.config);
    }

    fn render_scene(&mut self, scene: &Scene, clear_color: Color) -> Result<(), EngineError> {
        let frame = self
            .surface
            .get_current_texture()
            .map_err(|e| EngineError::Wgpu(format!("acquire: {e:?}")))?;

        self.renderer
            .render_to_surface(
                &self.device,
                &self.queue,
                scene,
                &frame,
                &vello::RenderParams {
                    base_color: clear_color,
                    width: self.size.0,
                    height: self.size.1,
                    antialiasing_method: vello::AaConfig::Msaa16,
                },
            )
            .map_err(|e| EngineError::Vello(format!("{e:?}")))?;

        frame.present();
        Ok(())
    }
}

struct Engine {
    gfx: Gfx,
    scene: Scene,
    time_s: f64,
    font_cx: FontContext,
    layout_cx: LayoutContext<Brush>,
    fonts: Vec<Vec<u8>>,
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
        McorePlatform::MacOS => {
            let mac = unsafe { desc.u.macos };
            // block_on in a new thread so we don't block AppKit
            match pollster::block_on(Gfx::new_macos(&mac)) {
                Ok(engine) => {
                    let eng = Engine {
                        gfx: engine,
                        scene: Scene::new(),
                        time_s: 0.0,
                        font_cx: FontContext::default(),
                        layout_cx: LayoutContext::new(),
                        fonts: Vec::new(),
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
    if let McorePlatform::MacOS = desc.platform {
        let mac = unsafe { desc.u.macos };
        let mut guard = ctx.0.lock();
        guard.gfx.resize(
            mac.width_px.max(1) as u32,
            mac.height_px.max(1) as u32,
            mac.scale_factor,
        );
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

    let shape = kurbo::RoundedRect::new(
        rect.x as f64,
        rect.y as f64,
        (rect.x + rect.w) as f64,
        (rect.y + rect.h) as f64,
        rect.radius as f64,
    );

    let color = Color::rgba(
        rect.fill.r as f64,
        rect.fill.g as f64,
        rect.fill.b as f64,
        rect.fill.a as f64,
    );

    guard.scene.fill(
        vello::peniko::Fill::NonZero,
        kurbo::Affine::IDENTITY,
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
    let font_data = data.to_vec();

    guard.font_cx.collection.register_fonts(font_data.clone());
    guard.fonts.push(font_data);

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

    // Simplified: just return estimated metrics based on font size
    let char_count = text.chars().count();
    let est_width = (char_count as f32 * req.font_size_px * 0.6).min(req.wrap_width);
    let est_lines = ((char_count as f32 * req.font_size_px * 0.6) / req.wrap_width).ceil().max(1.0);

    out.advance_w = est_width;
    out.advance_h = req.font_size_px * est_lines;
    out.line_count = est_lines as i32;
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

    // Simplified text rendering: draw each character as a rectangle
    // This is a placeholder - full text rendering would use proper font outlines
    let char_width = req.font_size_px * 0.6;
    let char_height = req.font_size_px;

    let brush = Brush::Solid(Color::rgba(
        color.r as f64,
        color.g as f64,
        color.b as f64,
        color.a as f64,
    ));

    let mut x_offset = 0.0;
    let mut y_offset = 0.0;

    for ch in text.chars() {
        if ch == '\n' || x_offset + char_width > req.wrap_width {
            x_offset = 0.0;
            y_offset += char_height * 1.2;
        }

        if ch != '\n' && !ch.is_whitespace() {
            let char_rect = kurbo::Rect::new(
                (x + x_offset) as f64,
                (y + y_offset) as f64,
                (x + x_offset + char_width * 0.8) as f64,
                (y + y_offset + char_height * 0.8) as f64,
            );

            guard.scene.fill(
                vello::peniko::Fill::NonZero,
                kurbo::Affine::IDENTITY,
                &brush,
                None,
                &char_rect,
            );
        }

        x_offset += char_width;
    }
}

#[no_mangle]
pub extern "C" fn mcore_end_frame_present(ctx: *mut McoreContext, clear: McoreRgba) -> McoreStatus {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();

    // Animate clear color based on time
    let t = guard.time_s as f32;
    let clear_color = Color::rgba(
        (clear.r + 0.05 * (t).sin()).clamp(0.0, 1.0) as f64,
        (clear.g + 0.05 * (t * 1.3).sin()).clamp(0.0, 1.0) as f64,
        (clear.b + 0.05 * (t * 1.7).sin()).clamp(0.0, 1.0) as f64,
        clear.a as f64,
    );

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
