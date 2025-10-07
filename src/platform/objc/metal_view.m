#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CVDisplayLink.h>

typedef void (*mv_frame_cb_t)(double t);
typedef void (*mv_resize_cb_t)(int w, int h, float scale);
typedef void (*mv_key_cb_t)(int key, unsigned int char_code, bool shift, bool cmd);
typedef void (*mv_mouse_cb_t)(int event_type, float x, float y);
typedef void (*mv_scroll_cb_t)(float delta_x, float delta_y);
typedef void (*mv_ime_commit_cb_t)(const char* text);
typedef void (*mv_ime_preedit_cb_t)(const char* text, int cursor_offset);
typedef struct { float x, y, w, h; } mv_ime_rect_t;
typedef mv_ime_rect_t (*mv_ime_cursor_rect_cb_t)(void);

static mv_frame_cb_t g_frame_cb = 0;
static mv_resize_cb_t g_resize_cb = 0;
static mv_key_cb_t g_key_cb = 0;
static mv_mouse_cb_t g_mouse_cb = 0;
static mv_scroll_cb_t g_scroll_cb = 0;
static mv_ime_commit_cb_t g_ime_commit_cb = 0;
static mv_ime_preedit_cb_t g_ime_preedit_cb = 0;
static mv_ime_cursor_rect_cb_t g_ime_cursor_rect_cb = 0;

@interface MVMetalView : NSView <NSTextInputClient>
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic) NSRange markedRange;
@property(nonatomic) NSRange currentSelectedRange;
@property(nonatomic) BOOL handledByIME;  // Track if last key was handled by IME
@end

@implementation MVMetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (BOOL)wantsUpdateLayer { return YES; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.wantsLayer = YES;
    if (![self.layer isKindOfClass:[CAMetalLayer class]]) {
        self.layer = [CAMetalLayer layer];
    }
    CAMetalLayer *layer = (CAMetalLayer*)self.layer;
    layer.pixelFormat = MTLPixelFormatRGBA8Unorm;
    layer.opaque = YES;

    // Make this view the first responder immediately
    [self.window makeFirstResponder:self];

    // Add tracking area for continuous mouse move events
    NSTrackingArea *trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
        options:(NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect | NSTrackingMouseMoved)
        owner:self
        userInfo:nil];
    [self addTrackingArea:trackingArea];
}
- (void)layout {
    [super layout];
    if (g_resize_cb) {
        NSRect b = self.bounds;
        CGFloat scale = self.window.backingScaleFactor;
        g_resize_cb((int)(b.size.width * scale), (int)(b.size.height * scale), (float)scale);
    }
}
- (void)keyDown:(NSEvent *)event {
    // Only use NSTextInputClient if IME callbacks are set up
    if (g_ime_commit_cb && g_ime_preedit_cb) {
        // Reset flag before interpretKeyEvents
        self.handledByIME = NO;

        // Let NSTextInputClient handle the event first (for IME)
        [self interpretKeyEvents:@[event]];

        // Only handle with key callback if IME didn't handle it
        if (!self.handledByIME && g_key_cb) {
            bool shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
            bool cmd = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
            unsigned int char_code = 0;

            // Get the character if it's a printable character
            NSString *chars = [event charactersIgnoringModifiers];
            if (chars.length > 0) {
                unichar ch = [chars characterAtIndex:0];
                // Only pass printable ASCII and common Unicode
                if (ch >= 32 && ch < 127) {
                    char_code = ch;
                }
            }

            g_key_cb(event.keyCode, char_code, shift, cmd);
        }
    } else {
        // Fallback to original behavior if IME not set up
        if (g_key_cb) {
            bool shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
            bool cmd = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
            unsigned int char_code = 0;

            // Get the character if it's a printable character
            NSString *chars = [event charactersIgnoringModifiers];
            if (chars.length > 0) {
                unichar ch = [chars characterAtIndex:0];
                // Only pass printable ASCII and common Unicode
                if (ch >= 32 && ch < 127) {
                    char_code = ch;
                }
            }

            g_key_cb(event.keyCode, char_code, shift, cmd);
        }
    }
}

// NSTextInputClient protocol methods
//
// NOTE: This implementation supports:
//   ✅ Emoji picker and simple IME
//   ✅ Dead keys (accents, etc.)
//   ⚠️  Korean/Japanese/Chinese composing characters have limitations
//       (First character works, but multi-part composition may crash)
//
// Future work: Proper multi-part composition tracking for CJK languages
// would require more sophisticated state management of marked text ranges.
//
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    @autoreleasepool {
        // Mark that IME handled this key
        self.handledByIME = YES;

        // Clear any marked text
        self.markedText = nil;
        self.markedRange = NSMakeRange(NSNotFound, 0);

        // Safety check: ensure we have a callback before proceeding
        if (!g_ime_commit_cb) {
            return;
        }

        // Get the string to insert
        NSString *text = nil;
        if ([string isKindOfClass:[NSAttributedString class]]) {
            text = [(NSAttributedString *)string string];
        } else if ([string isKindOfClass:[NSString class]]) {
            text = (NSString *)string;
        } else {
            // Unknown type, bail out safely
            return;
        }

        // Notify Zig of committed text
        if (text && text.length > 0) {
            const char* utf8 = [text UTF8String];
            if (utf8) {
                g_ime_commit_cb(utf8);
            }
        }
    }
}

- (void)setMarkedText:(id)string
        selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange {
    @autoreleasepool {
        // Mark that IME handled this key
        self.handledByIME = YES;

        // Safety check: ensure we have a callback before proceeding
        if (!g_ime_preedit_cb) {
            return;
        }

        // Get the marked text
        NSString *text = nil;
        if ([string isKindOfClass:[NSAttributedString class]]) {
            text = [(NSAttributedString *)string string];
        } else if ([string isKindOfClass:[NSString class]]) {
            text = (NSString *)string;
        } else {
            // Unknown type, bail out safely
            return;
        }

        self.markedText = text;

        if (!text || text.length == 0) {
            // Empty marked text means composition ended
            self.markedRange = NSMakeRange(NSNotFound, 0);
            g_ime_preedit_cb("", 0);
        } else {
            // Update marked range
            self.markedRange = NSMakeRange(0, text.length);

            // Notify Zig of preedit text
            const char* utf8 = [text UTF8String];
            if (utf8) {
                g_ime_preedit_cb(utf8, (int)selectedRange.location);
            }
        }

        [self setNeedsDisplay:YES];
    }
}

- (void)unmarkText {
    self.markedText = nil;
    self.markedRange = NSMakeRange(NSNotFound, 0);

    if (g_ime_preedit_cb) {
        g_ime_preedit_cb("", 0);
    }
}

- (NSRange)selectedRange {
    return self.currentSelectedRange;
}

- (NSRange)markedRange {
    return self.markedRange;
}

- (BOOL)hasMarkedText {
    return self.markedText != nil && self.markedText.length > 0;
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                actualRange:(NSRangePointer)actualRange {
    return nil;
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    // Get cursor position from Zig for IME popup positioning
    if (g_ime_cursor_rect_cb) {
        mv_ime_rect_t rect = g_ime_cursor_rect_cb();

        // TODO: Fix coordinate conversion for emoji picker positioning
        // Currently the picker appears far from the cursor. Need to properly
        // convert from view pixel coordinates to screen coordinates, accounting
        // for window position, backing scale factor, and macOS coordinate system
        // (origin at bottom-left).

        // Convert from window coordinates to screen coordinates
        NSRect windowRect = NSMakeRect(rect.x, rect.y, rect.w, rect.h);
        NSRect screenRect = [self.window convertRectToScreen:windowRect];

        return screenRect;
    }

    // Fallback to bottom-left corner
    NSRect windowRect = NSMakeRect(0, self.bounds.size.height, 1, 20);
    return [self.window convertRectToScreen:windowRect];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return 0;
}

- (void)doCommandBySelector:(SEL)selector {
    // This method is called by interpretKeyEvents: when it encounters
    // a command that should be handled by the application (like arrow keys,
    // delete, etc.) rather than by the IME.
    //
    // For now, we just mark that IME handled it (preventing double handling)
    // and let the key fall through to our normal key handling.
    // This prevents crashes when switching keyboards or using special keys.
    self.handledByIME = NO;  // Allow these keys to be handled normally
}

- (void)mouseDown:(NSEvent *)event {
    if (g_mouse_cb) {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        // Pass logical pixel coordinates (layout is in logical pixels)
        g_mouse_cb(0, (float)p.x, (float)p.y); // 0 = mouse down
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (g_mouse_cb) {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        // Pass logical pixel coordinates (layout is in logical pixels)
        g_mouse_cb(1, (float)p.x, (float)p.y); // 1 = mouse up
    }
}

- (void)mouseMoved:(NSEvent *)event {
    if (g_mouse_cb) {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        // Pass logical pixel coordinates (layout is in logical pixels)
        g_mouse_cb(2, (float)p.x, (float)p.y); // 2 = mouse moved
    }
}

- (void)mouseDragged:(NSEvent *)event {
    // Treat drag as move for now
    [self mouseMoved:event];
}

- (void)scrollWheel:(NSEvent *)event {
    if (g_scroll_cb) {
        // Get current mouse position
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];

        // Use scrollingDeltaX/Y for precise trackpad/wheel scrolling
        // These values are already in points and include native macOS momentum/acceleration
        CGFloat deltaX = event.scrollingDeltaX;
        CGFloat deltaY = event.scrollingDeltaY;

        CGFloat scale = self.window.backingScaleFactor;

        // Update mouse position first (in logical pixels, consistent with other mouse events)
        if (g_mouse_cb) {
            g_mouse_cb(2, (float)p.x, (float)p.y); // 2 = mouse moved
        }

        // Pass scroll deltas in physical pixels (they will be scaled to logical in Zig)
        g_scroll_cb((float)deltaX, (float)deltaY);
    }
}
@end

@interface MVApp : NSObject
@property(strong) NSWindow *window;
@property(strong) MVMetalView *view;
@property(strong) NSTimer *timer;
@end

@implementation MVApp
@end

static MVApp *GApp;

void* mv_app_init(int width, int height, const char* ctitle) {
    @autoreleasepool {
        if (!NSApp) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        }
        GApp = [MVApp new];

        NSRect rect = NSMakeRect(100, 100, width, height);
        NSString *title = [NSString stringWithUTF8String:ctitle ?: "Zig Host"];
        GApp.window = [[NSWindow alloc] initWithContentRect:rect
                                                  styleMask:(NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskResizable |
                                                             NSWindowStyleMaskMiniaturizable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        [GApp.window setTitle:title];

        GApp.view = [MVMetalView new];
        GApp.view.frame = ((NSView *)GApp.window.contentView).bounds;
        GApp.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [GApp.window setContentView:GApp.view];

        [GApp.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        // 60 fps timer - use common modes to keep firing during resize
        GApp.timer = [NSTimer timerWithTimeInterval:(1.0/60.0)
                                             repeats:YES
                                               block:^(__unused NSTimer *t) {
            static double t0 = 0;
            double now = CFAbsoluteTimeGetCurrent();
            if (t0 == 0) t0 = now;
            if (g_frame_cb) g_frame_cb(now - t0);
        }];
        [[NSRunLoop currentRunLoop] addTimer:GApp.timer forMode:NSRunLoopCommonModes];
        return (__bridge void*)GApp;
    }
}

void* mv_get_ns_view(void) {
    return (__bridge void*)GApp.view;
}

void* mv_get_metal_layer(void) {
    return (__bridge void*)GApp.view.layer;
}

void mv_set_frame_callback(mv_frame_cb_t cb) {
    g_frame_cb = cb;
}

void mv_set_resize_callback(mv_resize_cb_t cb) {
    g_resize_cb = cb;
}

void mv_set_key_callback(mv_key_cb_t cb) {
    g_key_cb = cb;
}

void mv_set_mouse_callback(mv_mouse_cb_t cb) {
    g_mouse_cb = cb;
}

void mv_set_scroll_callback(mv_scroll_cb_t cb) {
    g_scroll_cb = cb;
}

void mv_set_ime_commit_callback(mv_ime_commit_cb_t cb) {
    g_ime_commit_cb = cb;
}

void mv_set_ime_preedit_callback(mv_ime_preedit_cb_t cb) {
    g_ime_preedit_cb = cb;
}

void mv_set_ime_cursor_rect_callback(mv_ime_cursor_rect_cb_t cb) {
    g_ime_cursor_rect_cb = cb;
}

void mv_app_run(void) {
    [NSApp run];
}

// Clipboard functions
void mv_clipboard_set_text(const char* text) {
    @autoreleasepool {
        if (!text) return;
        NSString *str = [NSString stringWithUTF8String:text];
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard setString:str forType:NSPasteboardTypeString];
    }
}

int mv_clipboard_get_text(char* buffer, int buffer_len) {
    @autoreleasepool {
        if (!buffer || buffer_len <= 0) return 0;

        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        NSString *str = [pasteboard stringForType:NSPasteboardTypeString];

        if (!str) {
            buffer[0] = '\0';
            return 0;
        }

        const char* utf8 = [str UTF8String];
        if (!utf8) {
            buffer[0] = '\0';
            return 0;
        }

        int len = (int)strlen(utf8);
        int copy_len = (len < buffer_len - 1) ? len : (buffer_len - 1);
        memcpy(buffer, utf8, copy_len);
        buffer[copy_len] = '\0';
        return copy_len;
    }
}

void mv_app_quit(void) {
    [NSApp terminate:nil];
}

void mv_trigger_initial_resize(void) {
    // Manually trigger resize callback with actual view size
    // Call this after setting up the resize callback
    if (g_resize_cb && GApp && GApp.view) {
        NSRect b = GApp.view.bounds;
        CGFloat scale = GApp.window.backingScaleFactor;
        g_resize_cb((int)(b.size.width * scale), (int)(b.size.height * scale), (float)scale);
    }
}
