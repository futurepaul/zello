use parking_lot::Mutex;
use raw_window_handle::{AppKitDisplayHandle, AppKitWindowHandle, RawDisplayHandle, RawWindowHandle};
use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::Arc;

#[derive(Debug, thiserror::Error)]
enum EngineError {
    #[error("wgpu error: {0}")]
    Wgpu(String),
    #[error("invalid surface")]
    InvalidSurface,
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

struct Gfx {
    instance: wgpu::Instance,
    surface: wgpu::Surface<'static>,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
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

        let (device, queue) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("mcore-device"),
                    required_features: wgpu::Features::empty(),
                    required_limits: wgpu::Limits::downlevel_defaults(),
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

        Ok(Self {
            instance,
            surface,
            adapter,
            device,
            queue,
            config,
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

    fn render_clear(&mut self, rgba: [f32; 4]) -> Result<(), EngineError> {
        let frame = self
            .surface
            .get_current_texture()
            .map_err(|e| EngineError::Wgpu(format!("acquire: {e:?}")))?;
        let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("mcore-encoder"),
            });

        {
            let _rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("mcore-clear"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: rgba[0] as f64,
                            g: rgba[1] as f64,
                            b: rgba[2] as f64,
                            a: rgba[3] as f64,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
        }

        self.queue.submit(std::iter::once(encoder.finish()));
        frame.present();
        Ok(())
    }
}

struct Engine {
    gfx: Gfx,
    time_s: f64,
}

#[repr(C)]
pub struct McoreRgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
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
                        time_s: 0.0,
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
        guard
            .gfx
            .resize(mac.width_px.max(1) as u32, mac.height_px.max(1) as u32, mac.scale_factor);
    }
}

#[no_mangle]
pub extern "C" fn mcore_begin_frame(ctx: *mut McoreContext, time_seconds: f64) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();
    guard.time_s = time_seconds;
}

#[no_mangle]
pub extern "C" fn mcore_end_frame_present(ctx: *mut McoreContext, clear: McoreRgba) -> McoreStatus {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();

    // animate the clear a tiny bit so you know frames are ticking
    let t = guard.time_s as f32;
    let c = [
        (clear.r + 0.1 * (t).sin()).clamp(0.0, 1.0),
        (clear.g + 0.1 * (t * 1.3).sin()).clamp(0.0, 1.0),
        (clear.b + 0.1 * (t * 1.7).sin()).clamp(0.0, 1.0),
        clear.a,
    ];

    match guard.gfx.render_clear(c) {
        Ok(_) => McoreStatus::Ok,
        Err(e) => {
            set_err(e);
            McoreStatus::Err
        }
    }
}
