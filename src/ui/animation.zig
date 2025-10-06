/// Simple, self-contained animation and easing functions
/// Low-level and easy to customize - no abstractions!

/// Linear interpolation between two values
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Ease-in-out cubic (smooth start and end)
/// Good default for most animations
pub fn easeInOutCubic(t: f32) f32 {
    const t_clamped = @max(0.0, @min(1.0, t));
    if (t_clamped < 0.5) {
        return 4.0 * t_clamped * t_clamped * t_clamped;
    } else {
        const f = (2.0 * t_clamped - 2.0);
        return 1.0 + f * f * f / 2.0;
    }
}

/// Ease-out cubic (fast start, slow end)
/// Good for elements entering the screen
pub fn easeOutCubic(t: f32) f32 {
    const t_clamped = @max(0.0, @min(1.0, t));
    const f = t_clamped - 1.0;
    return 1.0 + f * f * f;
}

/// Ease-in cubic (slow start, fast end)
/// Good for elements leaving the screen
pub fn easeInCubic(t: f32) f32 {
    const t_clamped = @max(0.0, @min(1.0, t));
    return t_clamped * t_clamped * t_clamped;
}

/// Ease-in-out quadratic (gentler curve than cubic)
pub fn easeInOutQuad(t: f32) f32 {
    const t_clamped = @max(0.0, @min(1.0, t));
    if (t_clamped < 0.5) {
        return 2.0 * t_clamped * t_clamped;
    } else {
        const f = -2.0 * t_clamped + 2.0;
        return 1.0 - f * f / 2.0;
    }
}

/// Ease-out quadratic
pub fn easeOutQuad(t: f32) f32 {
    const t_clamped = @max(0.0, @min(1.0, t));
    return 1.0 - (1.0 - t_clamped) * (1.0 - t_clamped);
}

/// Ease-in quadratic
pub fn easeInQuad(t: f32) f32 {
    const t_clamped = @max(0.0, @min(1.0, t));
    return t_clamped * t_clamped;
}

/// Calculate animation progress with easing
/// Returns a value from 0.0 to 1.0 based on elapsed time and duration
///
/// Usage:
///   const t = animationProgress(start_time, current_time, 0.3, easeInOutCubic);
///   const value = lerp(start_value, end_value, t);
pub fn animationProgress(start_time: f64, current_time: f64, duration: f32, easing_fn: *const fn (f32) f32) f32 {
    const elapsed = @as(f32, @floatCast(current_time - start_time));
    const raw_t = elapsed / duration;
    const clamped_t = @max(0.0, @min(1.0, raw_t));
    return easing_fn(clamped_t);
}

/// Check if an animation is complete
pub fn isAnimationComplete(start_time: f64, current_time: f64, duration: f32) bool {
    const elapsed = @as(f32, @floatCast(current_time - start_time));
    return elapsed >= duration;
}
