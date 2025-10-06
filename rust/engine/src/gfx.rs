// Graphics module - handles wgpu + Vello rendering

use peniko::Color;
use raw_window_handle::{AppKitDisplayHandle, AppKitWindowHandle, RawDisplayHandle, RawWindowHandle};
use std::ffi::c_void;
use std::ptr::NonNull;
use vello::{AaConfig, AaSupport, RenderParams, Renderer, RendererOptions, Scene};

#[derive(Debug, thiserror::Error)]
pub enum GfxError {
    #[error("wgpu error: {0}")]
    Wgpu(String),
    #[error("invalid surface")]
    InvalidSurface,
    #[error("vello error: {0}")]
    Vello(String),
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct MacSurface {
    pub ns_view: *mut c_void,        // NSView*
    pub ca_metal_layer: *mut c_void, // CAMetalLayer*
    pub scale_factor: f32,
    pub width_px: i32,
    pub height_px: i32,
}

pub struct Gfx {
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
    pub async fn new_macos(desc: &MacSurface) -> Result<Self, GfxError> {
        // SAFETY: we trust the caller to pass a valid NSView* and CAMetalLayer*.
        // raw-window-handle only needs the NSView pointer populated.
        let ns_view = NonNull::new(desc.ns_view).ok_or(GfxError::InvalidSurface)?;
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
                .map_err(|e| GfxError::Wgpu(format!("{e:?}")))?
        };

        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
            .map_err(|e| GfxError::Wgpu(format!("{e:?}")))?;

        // Request device with higher limits for Vello
        let mut limits = wgpu::Limits::default();
        limits.max_storage_buffers_per_shader_stage = 8;

        let (device, queue) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("Vello Device"),
                    required_features: wgpu::Features::empty(),
                    required_limits: limits,
                    memory_hints: wgpu::MemoryHints::default(),
                    trace: wgpu::Trace::Off,
                },
            )
            .await
            .map_err(|e| GfxError::Wgpu(format!("{e:?}")))?;

        let w = desc.width_px as u32;
        let h = desc.height_px as u32;

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: wgpu::TextureFormat::Bgra8Unorm,
            width: w,
            height: h,
            present_mode: wgpu::PresentMode::Fifo,
            alpha_mode: wgpu::CompositeAlphaMode::Opaque,
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);

        let renderer_opts = RendererOptions {
            use_cpu: false,
            antialiasing_support: AaSupport {
                area: true,
                msaa8: false,
                msaa16: false,
            },
            num_init_threads: None,
            pipeline_cache: None,
        };

        let renderer = Renderer::new(&device, renderer_opts).map_err(|e| GfxError::Vello(format!("{e:?}")))?;

        let shader_src = include_str!("blit.wgsl");
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Blit Shader"),
            source: wgpu::ShaderSource::Wgsl(shader_src.into()),
        });

        let blit_bind_group_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("Blit Bind Group Layout"),
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
            label: Some("Blit Pipeline Layout"),
            bind_group_layouts: &[&blit_bind_group_layout],
            push_constant_ranges: &[],
        });

        let blit_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Blit Pipeline"),
            layout: Some(&blit_pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Bgra8Unorm,
                    blend: Some(wgpu::BlendState::REPLACE),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Blit Sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::FilterMode::Linear,
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

    pub fn resize(&mut self, desc: &MacSurface) -> Result<(), GfxError> {
        let w = desc.width_px as u32;
        let h = desc.height_px as u32;
        self.size = (w, h);
        self.scale = desc.scale_factor;

        self.config.width = w;
        self.config.height = h;
        self.surface.configure(&self.device, &self.config);
        Ok(())
    }

    pub fn scale(&self) -> f32 {
        self.scale
    }

    pub fn render_scene(&mut self, scene: &Scene, clear: Color) -> Result<(), GfxError> {
        let (w, h) = self.size;

        // 1) Render Vello scene to an intermediate RGBA8Unorm texture
        let vello_size = wgpu::Extent3d {
            width: w,
            height: h,
            depth_or_array_layers: 1,
        };
        let vello_texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("Vello Target"),
            size: vello_size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                | wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::STORAGE_BINDING,
            view_formats: &[],
        });
        let vello_view = vello_texture.create_view(&wgpu::TextureViewDescriptor::default());

        let params = RenderParams {
            base_color: clear,
            width: w,
            height: h,
            antialiasing_method: AaConfig::Area,
        };

        self.renderer
            .render_to_texture(&self.device, &self.queue, scene, &vello_view, &params)
            .map_err(|e| GfxError::Vello(format!("{e:?}")))?;

        // 2) Blit from vello_texture (Rgba8Unorm) to surface (Bgra8Unorm)
        let frame = self
            .surface
            .get_current_texture()
            .map_err(|e| GfxError::Wgpu(format!("get_current_texture: {e:?}")))?;

        let frame_view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Blit Bind Group"),
            layout: &self.blit_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&vello_view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&self.sampler),
                },
            ],
        });

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("Blit Encoder"),
            });

        {
            let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("Blit Pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &frame_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            rpass.set_pipeline(&self.blit_pipeline);
            rpass.set_bind_group(0, &bind_group, &[]);
            rpass.draw(0..6, 0..1);
        }

        self.queue.submit(Some(encoder.finish()));
        frame.present();

        Ok(())
    }
}
