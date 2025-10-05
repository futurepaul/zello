use parking_lot::Mutex;
use parley::layout::{Alignment, AlignmentOptions, Layout, PositionedLayoutItem};
use parley::style::{FontStack, StyleProperty};
use parley::{FontContext, LayoutContext};
use peniko::{kurbo, Blob, Brush, Color, FontData};
use raw_window_handle::{AppKitDisplayHandle, AppKitWindowHandle, RawDisplayHandle, RawWindowHandle};
use std::ffi::{c_void, CStr};
use std::ptr::NonNull;
use std::sync::Arc;
use vello::peniko::Fill;
use vello::{AaConfig, AaSupport, Glyph, RenderParams, Renderer, RendererOptions, Scene};

mod text_input;

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

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreTextSize {
    pub width: f32,
    pub height: f32,
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
    pub _padding: [u8; 12],
}

struct Gfx {
    instance: wgpu::Instance,
    surface: wgpu::Surface<'static>,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    renderer: Renderer,
    blit_pipeline: wgpu::RenderPipeline,
    blit_bind_group_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
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
            .map_err(|e| EngineError::Wgpu(format!("{e:?}")))?;

        // Request device with higher limits for Vello
        let mut limits = wgpu::Limits::default();
        limits.max_storage_buffers_per_shader_stage = 8;

        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("mcore-device".into()),
                required_features: wgpu::Features::empty(),
                required_limits: limits,
                ..Default::default()
            })
            .await
            .map_err(|e| EngineError::Wgpu(format!("{e:?}")))?;

        let (w, h) = (desc.width_px.max(1) as u32, desc.height_px.max(1) as u32);
        let caps = surface.get_capabilities(&adapter);

        // Use native format - Vello's render_to_surface handles intermediate texture
        let format = caps.formats[0];

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
                use_cpu: false,
                antialiasing_support: AaSupport::all(),
                num_init_threads: std::num::NonZeroUsize::new(1),
                pipeline_cache: None,
            },
        )
        .map_err(|e| EngineError::Vello(format!("{e:?}")))?;

        // Create blit shader to copy Rgba8Unorm intermediate to surface
        let blit_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("blit".into()),
            source: wgpu::ShaderSource::Wgsl(include_str!("blit.wgsl").into()),
        });

        let blit_bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("blit_bgl".into()),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        let blit_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("blit_pl".into()),
            bind_group_layouts: &[&blit_bind_group_layout],
            push_constant_ranges: &[],
        });

        let blit_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("blit".into()),
            layout: Some(&blit_pipeline_layout),
            vertex: wgpu::VertexState {
                module: &blit_shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &blit_shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("blit_sampler".into()),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        Ok(Self {
            instance,
            surface,
            adapter,
            device,
            queue,
            config,
            renderer,
            blit_pipeline,
            blit_bind_group_layout,
            sampler,
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

        // Create intermediate Rgba8Unorm texture for Vello rendering
        let intermediate_tex = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("intermediate".into()),
            size: wgpu::Extent3d {
                width: self.size.0,
                height: self.size.1,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });

        let intermediate_view = intermediate_tex.create_view(&wgpu::TextureViewDescriptor::default());

        // Render Vello scene to intermediate texture
        self.renderer
            .render_to_texture(
                &self.device,
                &self.queue,
                scene,
                &intermediate_view,
                &RenderParams {
                    base_color: clear_color,
                    width: self.size.0,
                    height: self.size.1,
                    antialiasing_method: AaConfig::Msaa16,
                },
            )
            .map_err(|e| EngineError::Vello(format!("{e:?}")))?;

        // Blit intermediate to surface
        let surface_view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("blit_bg".into()),
            layout: &self.blit_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&intermediate_view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&self.sampler),
                },
            ],
        });

        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("blit_encoder".into()),
        });

        {
            let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("blit_pass".into()),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &surface_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                ..Default::default()
            });

            rpass.set_pipeline(&self.blit_pipeline);
            rpass.set_bind_group(0, &bind_group, &[]);
            rpass.draw(0..3, 0..1);
        }

        self.queue.submit([encoder.finish()]);
        frame.present();
        Ok(())
    }
}

struct TextContext {
    font_cx: FontContext,
    layout_cx: LayoutContext<Brush>,
}

struct Engine {
    gfx: Gfx,
    scene: Scene,
    time_s: f64,
    text_cx: TextContext,
    fonts: Vec<(Vec<u8>, FontData)>,
    text_inputs: text_input::TextInputManager,
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
                        text_cx: TextContext {
                            font_cx: FontContext::default(),
                            layout_cx: LayoutContext::new(),
                        },
                        fonts: Vec::new(),
                        text_inputs: text_input::TextInputManager::new(),
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

    let color = Color::new([
        rect.fill.r,
        rect.fill.g,
        rect.fill.b,
        rect.fill.a,
    ]);

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
    let scale = guard.gfx.scale;

    // Split borrows using raw pointers to avoid double mutable borrow
    let text_cx_ptr = &mut guard.text_cx as *mut TextContext;
    let mut layout: Layout<Brush> = unsafe {
        let text_cx = &mut *text_cx_ptr;
        let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, text, scale, true);
        builder.push_default(StyleProperty::FontSize(req.font_size_px));
        builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
        builder.build(text)
    };

    layout.break_all_lines(Some(req.wrap_width));
    layout.align(None, Alignment::Start, AlignmentOptions::default());

    let width = layout.width();

    // Calculate proper height using line metrics (includes line spacing)
    let mut total_height = 0.0f32;
    for line in layout.lines() {
        let metrics = line.metrics();
        total_height += metrics.line_height;
    }

    out.advance_w = width;
    out.advance_h = total_height;
    out.line_count = layout.len() as i32;
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

    let scale = guard.gfx.scale;

    // Split borrows using raw pointers to avoid double mutable borrow
    let text_cx_ptr = &mut guard.text_cx as *mut TextContext;
    let mut layout: Layout<Brush> = unsafe {
        let text_cx = &mut *text_cx_ptr;
        let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, text, scale, true);
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
        builder.build(text)
    };

    layout.break_all_lines(Some(max_width));
    layout.align(None, Alignment::Start, AlignmentOptions::default());

    out.width = layout.width();

    // Calculate proper height using line metrics (includes line spacing)
    let mut total_height = 0.0f32;
    for line in layout.lines() {
        let metrics = line.metrics();
        total_height += metrics.line_height;
    }

    out.height = total_height;
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

    let scale = guard.gfx.scale;
    let byte_offset = byte_offset.max(0) as usize;
    let byte_offset = byte_offset.min(text.len());

    // Split borrows
    let text_cx_ptr = &mut guard.text_cx as *mut TextContext;
    let mut layout: Layout<Brush> = unsafe {
        let text_cx = &mut *text_cx_ptr;
        let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, text, scale, true);
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
        builder.build(text)
    };

    // Measure cursor position by adding a marker character after the cursor position
    // This prevents trailing space collapse issues
    if byte_offset == 0 {
        return 0.0;
    }

    // Use a very large max_width to prevent wrapping in single-line inputs
    let max_width_no_wrap = 100000.0;

    if byte_offset >= text.len() {
        // Cursor at end - use marker to handle trailing spaces
        let text_with_marker = format!("{}|", text);
        let mut marked_layout: Layout<Brush> = unsafe {
            let text_cx = &mut *text_cx_ptr;
            let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, &text_with_marker, scale, true);
            builder.push_default(StyleProperty::FontSize(font_size));
            builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
            builder.build(&text_with_marker)
        };
        marked_layout.break_all_lines(Some(max_width_no_wrap));
        marked_layout.align(None, Alignment::Start, AlignmentOptions::default());

        // Measure marker
        let mut marker_layout: Layout<Brush> = unsafe {
            let text_cx = &mut *text_cx_ptr;
            let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, "|", scale, true);
            builder.push_default(StyleProperty::FontSize(font_size));
            builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
            builder.build("|")
        };
        marker_layout.break_all_lines(Some(max_width_no_wrap));
        marker_layout.align(None, Alignment::Start, AlignmentOptions::default());

        return marked_layout.width() - marker_layout.width();
    }

    // Get the substring up to the cursor and add a visible marker
    let text_up_to_cursor = &text[..byte_offset];
    let text_with_marker = format!("{}|", text_up_to_cursor);

    // Measure with the marker
    let mut marked_layout: Layout<Brush> = unsafe {
        let text_cx = &mut *text_cx_ptr;
        let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, &text_with_marker, scale, true);
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
        builder.build(&text_with_marker)
    };

    marked_layout.break_all_lines(Some(max_width_no_wrap));
    marked_layout.align(None, Alignment::Start, AlignmentOptions::default());

    // Now measure just the marker character to subtract its width
    let mut marker_layout: Layout<Brush> = unsafe {
        let text_cx = &mut *text_cx_ptr;
        let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, "|", scale, true);
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
        builder.build("|")
    };

    marker_layout.break_all_lines(Some(max_width_no_wrap));
    marker_layout.align(None, Alignment::Start, AlignmentOptions::default());

    marked_layout.width() - marker_layout.width()
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
    let scale = guard.gfx.scale;

    // Split borrows using raw pointers to avoid double mutable borrow
    let text_cx_ptr = &mut guard.text_cx as *mut TextContext;
    let mut layout: Layout<Brush> = unsafe {
        let text_cx = &mut *text_cx_ptr;
        let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, text, scale, true);
        builder.push_default(StyleProperty::FontSize(req.font_size_px));
        builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
        builder.build(text)
    };

    layout.break_all_lines(Some(req.wrap_width));
    layout.align(None, Alignment::Start, AlignmentOptions::default());

    let brush = Brush::Solid(Color::new([color.r, color.g, color.b, color.a]));

    // Render text using masonry_core's pattern
    for line in layout.lines() {
        for item in line.items() {
            let PositionedLayoutItem::GlyphRun(glyph_run) = item else {
                continue;
            };

            let mut glyph_x = glyph_run.offset();
            let glyph_y = glyph_run.baseline();
            let run = glyph_run.run();
            let font = run.font();
            let font_size = run.font_size();
            let coords = run.normalized_coords();

            guard
                .scene
                .draw_glyphs(font)
                .brush(&brush)
                .hint(false)
                .transform(kurbo::Affine::translate((x as f64, y as f64)))
                .font_size(font_size)
                .normalized_coords(coords)
                .draw(
                    Fill::NonZero,
                    glyph_run.glyphs().map(|glyph| {
                        let gx = glyph_x + glyph.x;
                        let gy = glyph_y - glyph.y;
                        glyph_x += glyph.advance;
                        vello::Glyph {
                            id: glyph.id,
                            x: gx,
                            y: gy,
                        }
                    }),
                );
        }
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
    use kurbo::Rect;
    let clip_rect = Rect::new(x as f64, y as f64, (x + width) as f64, (y + height) as f64);
    guard.scene.push_layer(vello::peniko::BlendMode::default(), 1.0, kurbo::Affine::IDENTITY, &clip_rect);
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

    for cmd in commands {
        match cmd.kind {
            0 => {
                // RoundedRect
                let shape = kurbo::RoundedRect::new(
                    cmd.x as f64,
                    cmd.y as f64,
                    (cmd.x + cmd.width) as f64,
                    (cmd.y + cmd.height) as f64,
                    cmd.radius as f64,
                );
                let color = Color::new([cmd.color[0], cmd.color[1], cmd.color[2], cmd.color[3]]);
                guard.scene.fill(Fill::NonZero, kurbo::Affine::IDENTITY, color, None, &shape);
            }
            1 => {
                // Text
                let text = unsafe { CStr::from_ptr(cmd.text_ptr) }.to_str().unwrap_or("");
                let scale = guard.gfx.scale;

                // Split borrows using raw pointers
                let text_cx_ptr = &mut guard.text_cx as *mut TextContext;
                let mut layout: Layout<Brush> = unsafe {
                    let text_cx = &mut *text_cx_ptr;
                    let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, text, scale, true);
                    builder.push_default(StyleProperty::FontSize(cmd.font_size));
                    builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
                    builder.build(text)
                };

                layout.break_all_lines(Some(cmd.wrap_width));
                layout.align(None, Alignment::Start, AlignmentOptions::default());

                let brush = Brush::Solid(Color::new([cmd.color[0], cmd.color[1], cmd.color[2], cmd.color[3]]));

                // Render text
                for line in layout.lines() {
                    for item in line.items() {
                        let PositionedLayoutItem::GlyphRun(glyph_run) = item else {
                            continue;
                        };

                        let mut glyph_x = glyph_run.offset();
                        let glyph_y = glyph_run.baseline();
                        let run = glyph_run.run();
                        let font = run.font();
                        let font_size = run.font_size();
                        let coords = run.normalized_coords();

                        guard
                            .scene
                            .draw_glyphs(font)
                            .brush(&brush)
                            .hint(false)
                            .transform(kurbo::Affine::translate((cmd.x as f64, cmd.y as f64)))
                            .font_size(font_size)
                            .normalized_coords(coords)
                            .draw(
                                Fill::NonZero,
                                glyph_run.glyphs().map(|glyph| {
                                    let gx = glyph_x + glyph.x;
                                    let gy = glyph_y - glyph.y;
                                    glyph_x += glyph.advance;
                                    vello::Glyph {
                                        id: glyph.id,
                                        x: gx,
                                        y: gy,
                                    }
                                }),
                            );
                    }
                }
            }
            2 => {
                // PushClip
                use kurbo::Rect;
                let clip_rect = Rect::new(
                    cmd.x as f64,
                    cmd.y as f64,
                    (cmd.x + cmd.width) as f64,
                    (cmd.y + cmd.height) as f64,
                );
                guard.scene.push_layer(vello::peniko::BlendMode::default(), 1.0, kurbo::Affine::IDENTITY, &clip_rect);
            }
            3 => {
                // PopClip
                guard.scene.pop_layer();
            }
            _ => {}
        }
    }
}

#[no_mangle]
pub extern "C" fn mcore_end_frame_present(ctx: *mut McoreContext, clear: McoreRgba) -> McoreStatus {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();

    // Animate clear color based on time
    let t = guard.time_s as f32;
    let clear_color = Color::new([
        (clear.r + 0.05 * (t).sin()).clamp(0.0, 1.0),
        (clear.g + 0.05 * (t * 1.3).sin()).clamp(0.0, 1.0),
        (clear.b + 0.05 * (t * 1.7).sin()).clamp(0.0, 1.0),
        clear.a,
    ]);

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
