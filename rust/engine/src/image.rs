/// Image management module
///
/// Handles image registration, reference counting, and storage.
/// Images are stored with Arc<Blob> for efficient sharing and GPU upload.

use peniko::{Blob, ImageData};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use vello::peniko::{ImageAlphaType, ImageFormat};

/// Entry in the image cache with reference counting
pub struct ImageEntry {
    pub image: ImageData,
    pub refcount: usize,
    pub width: u32,
    pub height: u32,
}

/// Image manager with reference-counted cache
pub struct ImageManager {
    images: HashMap<i32, ImageEntry>,
    next_id: i32,
}

impl ImageManager {
    /// Create a new image manager
    pub fn new() -> Self {
        Self {
            images: HashMap::new(),
            next_id: 0,
        }
    }

    /// Load an image from a file path (JPEG, PNG, etc.)
    /// Returns decoded RGBA8 pixels, width, and height
    pub fn load_image_file(path: impl AsRef<Path>) -> Result<(Vec<u8>, u32, u32), String> {
        let img = image::open(path)
            .map_err(|e| format!("Failed to load image: {}", e))?;

        let rgba = img.to_rgba8();
        let (width, height) = rgba.dimensions();
        let pixels = rgba.into_raw();

        Ok((pixels, width, height))
    }

    /// Load an image from bytes (JPEG, PNG, etc.)
    /// Returns decoded RGBA8 pixels, width, and height
    pub fn load_image_bytes(bytes: &[u8]) -> Result<(Vec<u8>, u32, u32), String> {
        let img = image::load_from_memory(bytes)
            .map_err(|e| format!("Failed to decode image: {}", e))?;

        let rgba = img.to_rgba8();
        let (width, height) = rgba.dimensions();
        let pixels = rgba.into_raw();

        Ok((pixels, width, height))
    }

    /// Convenience: Load and register an image from a file path
    pub fn register_from_file(&mut self, path: impl AsRef<Path>) -> Result<i32, String> {
        let (pixels, width, height) = Self::load_image_file(path)?;
        self.register(&pixels, width, height, ImageFormat::Rgba8, ImageAlphaType::Alpha)
    }

    /// Convenience: Load and register an image from bytes
    pub fn register_from_bytes(&mut self, bytes: &[u8]) -> Result<i32, String> {
        let (pixels, width, height) = Self::load_image_bytes(bytes)?;
        self.register(&pixels, width, height, ImageFormat::Rgba8, ImageAlphaType::Alpha)
    }

    /// Register a new image from raw pixel data
    /// Returns an image ID or -1 on error
    pub fn register(
        &mut self,
        pixels: &[u8],
        width: u32,
        height: u32,
        format: ImageFormat,
        alpha_type: ImageAlphaType,
    ) -> Result<i32, String> {
        // Validate dimensions (only RGBA8 supported for now)
        let expected_bpp = match format {
            ImageFormat::Rgba8 => 4,
            _ => return Err(format!("Unsupported image format: {:?}", format)),
        };

        let expected_len = (width as usize) * (height as usize) * expected_bpp;
        if pixels.len() != expected_len {
            return Err(format!(
                "Invalid pixel data length: expected {}, got {}",
                expected_len,
                pixels.len()
            ));
        }

        // Copy pixel data into Arc<Vec<u8>>
        let pixel_vec = pixels.to_vec();
        let blob = Blob::new(Arc::new(pixel_vec));

        // Create ImageData
        let image = ImageData {
            data: blob,
            format,
            width,
            height,
            alpha_type,
        };

        // Store with refcount = 1
        let id = self.next_id;
        self.next_id += 1;

        self.images.insert(
            id,
            ImageEntry {
                image,
                refcount: 1,
                width,
                height,
            },
        );

        Ok(id)
    }

    /// Increment reference count for an image
    pub fn retain(&mut self, id: i32) -> Result<(), String> {
        if let Some(entry) = self.images.get_mut(&id) {
            entry.refcount += 1;
            Ok(())
        } else {
            Err(format!("Image ID {} not found", id))
        }
    }

    /// Decrement reference count, freeing image when count reaches 0
    pub fn release(&mut self, id: i32) -> Result<bool, String> {
        if let Some(entry) = self.images.get_mut(&id) {
            entry.refcount -= 1;
            if entry.refcount == 0 {
                self.images.remove(&id);
                Ok(true) // Image was freed
            } else {
                Ok(false) // Image still has references
            }
        } else {
            Err(format!("Image ID {} not found", id))
        }
    }

    /// Get an image by ID
    pub fn get(&self, id: i32) -> Option<&ImageData> {
        self.images.get(&id).map(|entry| &entry.image)
    }

    /// Get image dimensions by ID
    pub fn get_dimensions(&self, id: i32) -> Option<(u32, u32)> {
        self.images.get(&id).map(|entry| (entry.width, entry.height))
    }

    /// Get the current reference count for an image
    #[allow(dead_code)]
    pub fn refcount(&self, id: i32) -> Option<usize> {
        self.images.get(&id).map(|entry| entry.refcount)
    }

    /// Get total number of images in cache
    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.images.len()
    }

    /// Check if cache is empty
    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.images.is_empty()
    }
}

impl Default for ImageManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_pixels(width: u32, height: u32) -> Vec<u8> {
        let size = (width * height * 4) as usize;
        vec![255u8; size]
    }

    #[test]
    fn test_register_image() {
        let mut manager = ImageManager::new();
        let pixels = create_test_pixels(2, 2);

        let id = manager
            .register(&pixels, 2, 2, ImageFormat::Rgba8, ImageAlphaType::Alpha)
            .unwrap();

        assert_eq!(id, 0);
        assert!(manager.get(id).is_some());
        assert_eq!(manager.refcount(id), Some(1));
    }

    #[test]
    fn test_refcount() {
        let mut manager = ImageManager::new();
        let pixels = create_test_pixels(2, 2);

        let id = manager
            .register(&pixels, 2, 2, ImageFormat::Rgba8, ImageAlphaType::Alpha)
            .unwrap();

        // Initial refcount is 1
        assert_eq!(manager.refcount(id), Some(1));

        // Retain
        manager.retain(id).unwrap();
        assert_eq!(manager.refcount(id), Some(2));

        // Release (should not free)
        let freed = manager.release(id).unwrap();
        assert!(!freed);
        assert_eq!(manager.refcount(id), Some(1));

        // Final release (should free)
        let freed = manager.release(id).unwrap();
        assert!(freed);
        assert!(manager.get(id).is_none());
    }

    #[test]
    fn test_invalid_dimensions() {
        let mut manager = ImageManager::new();
        let pixels = create_test_pixels(2, 2);

        // Wrong dimensions
        let result = manager.register(&pixels, 10, 10, ImageFormat::Rgba8, ImageAlphaType::Alpha);
        assert!(result.is_err());
    }

    #[test]
    fn test_rgba8_format() {
        let mut manager = ImageManager::new();
        let pixels = vec![255u8; 2 * 2 * 4]; // RGBA8

        let id = manager
            .register(&pixels, 2, 2, ImageFormat::Rgba8, ImageAlphaType::Alpha)
            .unwrap();

        assert!(manager.get(id).is_some());
    }
}
