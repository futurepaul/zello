#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

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

@interface MVMetalView : UIView <UITextInput>
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) CFTimeInterval startTime;

// UITextInput properties
@property(nonatomic, strong) NSString *markedText;
@property(nonatomic) NSRange markedRange;
@property(nonatomic) UITextRange *selectedTextRange;
@property(nonatomic, weak) id<UITextInputDelegate> inputDelegate;
@property(nonatomic, readonly) id<UITextInputTokenizer> tokenizer;
@property(nonatomic) UITextStorageDirection markedTextStyle;

// Keyboard management
@property(nonatomic) BOOL handledByIME;
@end

@implementation MVMetalView

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        // Set up Metal layer
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
        metalLayer.pixelFormat = MTLPixelFormatRGBA8Unorm;
        metalLayer.opaque = YES;
        metalLayer.framebufferOnly = YES;

        self.markedRange = NSMakeRange(NSNotFound, 0);

        // Set up display link (60fps)
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderFrame:)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        self.startTime = CACurrentMediaTime();
    }
    return self;
}

- (void)renderFrame:(CADisplayLink *)displayLink {
    if (g_frame_cb) {
        double now = CACurrentMediaTime();
        g_frame_cb(now - self.startTime);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (g_resize_cb) {
        CGFloat scale = self.window.screen.scale;
        CGSize size = self.bounds.size;
        g_resize_cb((int)(size.width * scale), (int)(size.height * scale), (float)scale);
    }
}

- (void)dealloc {
    [self.displayLink invalidate];
}

// ============================================================================
// Touch Handling
// ============================================================================

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (g_mouse_cb) {
        UITouch *touch = [touches anyObject];
        CGPoint p = [touch locationInView:self];
        g_mouse_cb(0, (float)p.x, (float)p.y); // 0 = mouse down
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (g_mouse_cb) {
        UITouch *touch = [touches anyObject];
        CGPoint p = [touch locationInView:self];
        g_mouse_cb(2, (float)p.x, (float)p.y); // 2 = mouse moved
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (g_mouse_cb) {
        UITouch *touch = [touches anyObject];
        CGPoint p = [touch locationInView:self];
        g_mouse_cb(1, (float)p.x, (float)p.y); // 1 = mouse up
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

// ============================================================================
// UITextInput Protocol (for keyboard input)
// ============================================================================

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)insertText:(NSString *)text {
    @autoreleasepool {
        self.handledByIME = YES;

        // Clear marked text
        self.markedText = nil;
        self.markedRange = NSMakeRange(NSNotFound, 0);

        if (g_ime_commit_cb && text.length > 0) {
            const char* utf8 = [text UTF8String];
            if (utf8) {
                g_ime_commit_cb(utf8);
            }
        }

        if (self.inputDelegate) {
            [self.inputDelegate textDidChange:self];
        }
    }
}

- (void)deleteBackward {
    // Handle backspace - send as a key event
    if (g_key_cb) {
        g_key_cb(42, 0, false, false); // 42 is typical backspace keycode
    }
}

- (void)setMarkedText:(NSString *)markedText selectedRange:(NSRange)selectedRange {
    @autoreleasepool {
        self.handledByIME = YES;
        self.markedText = markedText;

        if (!markedText || markedText.length == 0) {
            self.markedRange = NSMakeRange(NSNotFound, 0);
            if (g_ime_preedit_cb) {
                g_ime_preedit_cb("", 0);
            }
        } else {
            self.markedRange = NSMakeRange(0, markedText.length);
            if (g_ime_preedit_cb) {
                const char* utf8 = [markedText UTF8String];
                if (utf8) {
                    g_ime_preedit_cb(utf8, (int)selectedRange.location);
                }
            }
        }

        if (self.inputDelegate) {
            [self.inputDelegate textDidChange:self];
        }
    }
}

- (void)unmarkText {
    self.markedText = nil;
    self.markedRange = NSMakeRange(NSNotFound, 0);

    if (g_ime_preedit_cb) {
        g_ime_preedit_cb("", 0);
    }
}

// Required UITextInput methods (minimal implementation)

- (UITextRange *)textRangeFromPosition:(UITextPosition *)fromPosition toPosition:(UITextPosition *)toPosition {
    return nil;
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position offset:(NSInteger)offset {
    return nil;
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction offset:(NSInteger)offset {
    return nil;
}

- (NSComparisonResult)comparePosition:(UITextPosition *)position toPosition:(UITextPosition *)other {
    return NSOrderedSame;
}

- (NSInteger)offsetFromPosition:(UITextPosition *)from toPosition:(UITextPosition *)toPosition {
    return 0;
}

- (UITextPosition *)positionWithinRange:(UITextRange *)range farthestInDirection:(UITextLayoutDirection)direction {
    return nil;
}

- (UITextRange *)characterRangeByExtendingPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction {
    return nil;
}

- (NSWritingDirection)baseWritingDirectionForPosition:(UITextPosition *)position inDirection:(UITextStorageDirection)direction {
    return NSWritingDirectionLeftToRight;
}

- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection forRange:(UITextRange *)range {
}

- (CGRect)firstRectForRange:(UITextRange *)range {
    if (g_ime_cursor_rect_cb) {
        mv_ime_rect_t rect = g_ime_cursor_rect_cb();
        return CGRectMake(rect.x, rect.y, rect.w, rect.h);
    }
    return CGRectMake(0, 0, 1, 20);
}

- (CGRect)caretRectForPosition:(UITextPosition *)position {
    if (g_ime_cursor_rect_cb) {
        mv_ime_rect_t rect = g_ime_cursor_rect_cb();
        return CGRectMake(rect.x, rect.y, rect.w, rect.h);
    }
    return CGRectMake(0, 0, 1, 20);
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point {
    return nil;
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(UITextRange *)range {
    return nil;
}

- (NSArray *)selectionRectsForRange:(UITextRange *)range {
    return @[];
}

- (NSString *)textInRange:(UITextRange *)range {
    return @"";
}

- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    [self insertText:text];
}

// Text range and position properties

- (UITextRange *)selectedTextRange {
    return nil;
}

- (void)setSelectedTextRange:(UITextRange *)selectedTextRange {
}

- (NSRange)markedRange {
    return _markedRange;
}

- (NSDictionary *)markedTextStyle {
    return nil;
}

- (void)setMarkedTextStyle:(NSDictionary *)markedTextStyle {
}

- (UITextPosition *)beginningOfDocument {
    return nil;
}

- (UITextPosition *)endOfDocument {
    return nil;
}

- (id<UITextInputTokenizer>)tokenizer {
    return [[UITextInputStringTokenizer alloc] initWithTextInput:self];
}

@end

// ============================================================================
// View Controller
// ============================================================================

@interface MVViewController : UIViewController
@property(nonatomic, strong) MVMetalView *metalView;
@end

@implementation MVViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // Create and add metal view
    self.metalView = [[MVMetalView alloc] initWithFrame:self.view.bounds];
    self.metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.metalView];

    // Make it first responder for keyboard input
    [self.metalView becomeFirstResponder];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.metalView.frame = self.view.bounds;
}

@end

// ============================================================================
// App Delegate
// ============================================================================

@interface MVAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) MVViewController *viewController;
@end

@implementation MVAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Create window
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    // Create view controller
    self.viewController = [[MVViewController alloc] init];
    self.window.rootViewController = self.viewController;

    [self.window makeKeyAndVisible];

    return YES;
}

@end

// ============================================================================
// Global state
// ============================================================================

static MVAppDelegate *GAppDelegate;

// ============================================================================
// C API (matching macOS version)
// ============================================================================

void* mv_app_init(int width, int height, const char* ctitle) {
    @autoreleasepool {
        // Note: On iOS, width/height are ignored - we use full screen
        // Title is also ignored (no window title bar on iOS)

        // Create UIApplication if it doesn't exist
        // On iOS, sharedApplication will create it if needed
        UIApplication *app = [UIApplication sharedApplication];

        // Create our app delegate and set it
        GAppDelegate = [[MVAppDelegate alloc] init];

        // Manually trigger the app delegate's initialization
        // (normally done by UIApplicationMain)
        [GAppDelegate application:app didFinishLaunchingWithOptions:nil];

        return (__bridge void*)GAppDelegate;
    }
}

void* mv_get_ns_view(void) {
    return (__bridge void*)GAppDelegate.viewController.metalView;
}

void* mv_get_metal_layer(void) {
    return (__bridge void*)GAppDelegate.viewController.metalView.layer;
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
    @autoreleasepool {
        // Run the iOS run loop
        // This is similar to [NSApp run] on macOS
        [[NSRunLoop mainRunLoop] run];
    }
}

// Clipboard functions
void mv_clipboard_set_text(const char* text) {
    @autoreleasepool {
        if (!text) return;
        NSString *str = [NSString stringWithUTF8String:text];
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = str;
    }
}

int mv_clipboard_get_text(char* buffer, int buffer_len) {
    @autoreleasepool {
        if (!buffer || buffer_len <= 0) return 0;

        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        NSString *str = pasteboard.string;

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
    // iOS apps cannot programmatically quit
    // Apple rejects apps that call exit()
    // This is a no-op on iOS
}

void mv_trigger_initial_resize(void) {
    // Trigger resize callback with actual view size
    if (g_resize_cb && GAppDelegate && GAppDelegate.viewController.metalView) {
        MVMetalView *view = GAppDelegate.viewController.metalView;
        CGFloat scale = view.window.screen.scale;
        CGSize size = view.bounds.size;
        g_resize_cb((int)(size.width * scale), (int)(size.height * scale), (float)scale);
    }
}
