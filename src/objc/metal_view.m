#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CVDisplayLink.h>

typedef void (*mv_frame_cb_t)(double t);
typedef void (*mv_resize_cb_t)(int w, int h, float scale);
typedef void (*mv_key_cb_t)(int key, unsigned int char_code, bool shift);
typedef void (*mv_mouse_cb_t)(int event_type, float x, float y);

static mv_frame_cb_t g_frame_cb = 0;
static mv_resize_cb_t g_resize_cb = 0;
static mv_key_cb_t g_key_cb = 0;
static mv_mouse_cb_t g_mouse_cb = 0;

@interface MVMetalView : NSView
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
    if (g_key_cb) {
        bool shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
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

        g_key_cb(event.keyCode, char_code, shift);
    }
}

- (void)mouseDown:(NSEvent *)event {
    if (g_mouse_cb) {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        // Convert points to pixels to match rendering coordinate space
        CGFloat scale = self.window.backingScaleFactor;
        g_mouse_cb(0, (float)(p.x * scale), (float)(p.y * scale)); // 0 = mouse down
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (g_mouse_cb) {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        CGFloat scale = self.window.backingScaleFactor;
        g_mouse_cb(1, (float)(p.x * scale), (float)(p.y * scale)); // 1 = mouse up
    }
}

- (void)mouseMoved:(NSEvent *)event {
    if (g_mouse_cb) {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        CGFloat scale = self.window.backingScaleFactor;
        g_mouse_cb(2, (float)(p.x * scale), (float)(p.y * scale)); // 2 = mouse moved
    }
}

- (void)mouseDragged:(NSEvent *)event {
    // Treat drag as move for now
    [self mouseMoved:event];
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

        // 60 fps timer
        GApp.timer = [NSTimer scheduledTimerWithTimeInterval:(1.0/60.0)
                                                      repeats:YES
                                                        block:^(__unused NSTimer *t) {
            static double t0 = 0;
            double now = CFAbsoluteTimeGetCurrent();
            if (t0 == 0) t0 = now;
            if (g_frame_cb) g_frame_cb(now - t0);
        }];
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

void mv_app_run(void) {
    [NSApp run];
}
