#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CVDisplayLink.h>

typedef void (*mv_frame_cb_t)(double t);
typedef void (*mv_resize_cb_t)(int w, int h, float scale);

static mv_frame_cb_t g_frame_cb = 0;
static mv_resize_cb_t g_resize_cb = 0;

@interface MVMetalView : NSView
@end

@implementation MVMetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (BOOL)wantsUpdateLayer { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.wantsLayer = YES;
    if (![self.layer isKindOfClass:[CAMetalLayer class]]) {
        self.layer = [CAMetalLayer layer];
    }
    CAMetalLayer *layer = (CAMetalLayer*)self.layer;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
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

void mv_app_run(void) {
    [NSApp run];
}
