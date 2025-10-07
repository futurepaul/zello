// Text module - handles Parley text layout and measurement

use parley::layout::{Alignment, AlignmentOptions, Cursor, Layout, PositionedLayoutItem};
use parley::style::{FontStack, StyleProperty};
use parley::{FontContext, LayoutContext};
use peniko::{kurbo, Brush, Color};
use vello::Scene;

pub struct TextContext {
    pub font_cx: FontContext,
    pub layout_cx: LayoutContext<Brush>,
}

impl Default for TextContext {
    fn default() -> Self {
        Self {
            font_cx: FontContext::default(),
            layout_cx: LayoutContext::new(),
        }
    }
}

/// Measure text and return width and height
pub fn measure_text(
    text_cx: &mut TextContext,
    text: &str,
    font_size: f32,
    max_width: f32,
    scale: f32,
) -> (f32, f32) {
    let mut layout: Layout<Brush> = {
        let mut builder = text_cx
            .layout_cx
            .ranged_builder(&mut text_cx.font_cx, text, scale, true);
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source(
            "system-ui".into(),
        )));
        builder.build(text)
    };

    // Parley expects physical pixel coordinates, so scale max_width
    layout.break_all_lines(Some(max_width * scale));
    layout.align(None, Alignment::Start, AlignmentOptions::default());

    let width = layout.width();

    // Calculate proper height using line metrics (includes line spacing)
    let mut total_height = 0.0f32;
    for line in layout.lines() {
        let metrics = line.metrics();
        total_height += metrics.line_height;
    }

    // Layout returns physical pixels, convert to logical
    (width / scale, total_height / scale)
}

/// Measure text width up to a specific byte offset (kept for API compatibility)
pub fn measure_text_to_byte_offset(
    text_cx: &mut TextContext,
    text: &str,
    font_size: f32,
    byte_offset: usize,
    scale: f32,
) -> f32 {
    byte_offset_to_x(text_cx, text, font_size, byte_offset, scale)
}

/// Measure text and get a hit position (x coordinate) for a byte offset
pub fn byte_offset_to_x(
    text_cx: &mut TextContext,
    text: &str,
    font_size: f32,
    byte_offset: usize,
    scale: f32,
) -> f32 {
    let byte_offset = byte_offset.min(text.len());

    // Use a very large max_width to prevent wrapping in single-line inputs
    // Scale to physical pixels for Parley
    let max_width_no_wrap = 100000.0 * scale;

    // Measure cursor position by adding a marker character after the cursor position
    // This prevents trailing space collapse issues
    if byte_offset == 0 {
        return 0.0;
    }

    if byte_offset >= text.len() {
        // Cursor at end - use marker to handle trailing spaces
        let text_with_marker = format!("{}|", text);
        let mut marked_layout: Layout<Brush> = {
            let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, &text_with_marker, scale, true);
            builder.push_default(StyleProperty::FontSize(font_size));
            builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
            builder.build(&text_with_marker)
        };
        marked_layout.break_all_lines(Some(max_width_no_wrap));
        marked_layout.align(None, Alignment::Start, AlignmentOptions::default());

        // Measure marker
        let mut marker_layout: Layout<Brush> = {
            let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, "|", scale, true);
            builder.push_default(StyleProperty::FontSize(font_size));
            builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
            builder.build("|")
        };
        marker_layout.break_all_lines(Some(max_width_no_wrap));
        marker_layout.align(None, Alignment::Start, AlignmentOptions::default());

        // Layout returns physical pixels, convert to logical
        return (marked_layout.width() - marker_layout.width()) / scale;
    }

    // Get the substring up to the cursor and add a visible marker
    let text_up_to_cursor = &text[..byte_offset];
    let text_with_marker = format!("{}|", text_up_to_cursor);

    // Measure with the marker
    let mut marked_layout: Layout<Brush> = {
        let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, &text_with_marker, scale, true);
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
        builder.build(&text_with_marker)
    };

    marked_layout.break_all_lines(Some(max_width_no_wrap));
    marked_layout.align(None, Alignment::Start, AlignmentOptions::default());

    // Now measure just the marker character to subtract its width
    let mut marker_layout: Layout<Brush> = {
        let mut builder = text_cx.layout_cx.ranged_builder(&mut text_cx.font_cx, "|", scale, true);
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
        builder.build("|")
    };

    marker_layout.break_all_lines(Some(max_width_no_wrap));
    marker_layout.align(None, Alignment::Start, AlignmentOptions::default());

    // Layout returns physical pixels, convert to logical
    (marked_layout.width() - marker_layout.width()) / scale
}

/// Hit test text at an x coordinate and return the byte offset
pub fn x_to_byte_offset(
    text_cx: &mut TextContext,
    text: &str,
    font_size: f32,
    x: f32,
    scale: f32,
) -> usize {
    let mut layout: Layout<Brush> = {
        let mut builder = text_cx
            .layout_cx
            .ranged_builder(&mut text_cx.font_cx, text, scale, true);
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source(
            "system-ui".into(),
        )));
        builder.build(text)
    };

    // Use a very large max_width to prevent wrapping
    layout.break_all_lines(Some(100000.0));
    layout.align(None, Alignment::Start, AlignmentOptions::default());

    // Hit test at point
    let cursor = Cursor::from_point(&layout, x, 0.0);
    cursor.index()
}

/// Draw text into a Vello scene
pub fn draw_text(
    scene: &mut Scene,
    text_cx: &mut TextContext,
    text: &str,
    x: f32,
    y: f32,
    font_size: f32,
    wrap_width: f32,
    color: Color,
    scale: f32,
) {
    let mut layout: Layout<Brush> = {
        let mut builder = text_cx
            .layout_cx
            .ranged_builder(&mut text_cx.font_cx, text, scale, true);
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source(
            "system-ui".into(),
        )));
        builder.build(text)
    };

    // Parley expects physical pixel coordinates, so scale wrap_width
    layout.break_all_lines(Some(wrap_width * scale));
    layout.align(None, Alignment::Start, AlignmentOptions::default());

    let brush = Brush::Solid(color);

    // Render glyphs using the same pattern as original code
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

            scene
                .draw_glyphs(font)
                .brush(&brush)
                .hint(false)
                .transform(kurbo::Affine::translate((x as f64, y as f64)))
                .font_size(font_size)
                .normalized_coords(coords)
                .draw(
                    vello::peniko::Fill::NonZero,
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

/// Layout text and return full metrics (width, height, line count)
pub struct TextMetrics {
    pub width: f32,
    pub height: f32,
    pub line_count: usize,
}

pub fn layout_text(
    text_cx: &mut TextContext,
    text: &str,
    font_size: f32,
    wrap_width: f32,
    scale: f32,
) -> TextMetrics {
    let mut layout: Layout<Brush> = {
        let mut builder = text_cx
            .layout_cx
            .ranged_builder(&mut text_cx.font_cx, text, scale, true);
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source(
            "system-ui".into(),
        )));
        builder.build(text)
    };

    layout.break_all_lines(Some(wrap_width));
    layout.align(None, Alignment::Start, AlignmentOptions::default());

    let width = layout.width();

    // Calculate proper height using line metrics (includes line spacing)
    let mut total_height = 0.0f32;
    for line in layout.lines() {
        let metrics = line.metrics();
        total_height += metrics.line_height;
    }

    TextMetrics {
        width,
        height: total_height,
        line_count: layout.len(),
    }
}
