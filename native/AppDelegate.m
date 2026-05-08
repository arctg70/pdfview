#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AppDelegate.h"
#import "MuPDFRenderer.h"

// ── Toolbar item identifiers ────────────────────────────────────────
static NSString *const kToolbarOpen     = @"Open";
static NSString *const kToolbarPrevPage = @"PrevPage";
static NSString *const kToolbarNextPage = @"NextPage";
static NSString *const kToolbarPage     = @"PageField";
static NSString *const kToolbarZoomOut  = @"ZoomOut";
static NSString *const kToolbarZoom     = @"ZoomLabel";
static NSString *const kToolbarZoomIn   = @"ZoomIn";
static NSString *const kToolbarFitW     = @"FitWidth";
static NSString *const kToolbarFitP     = @"FitPage";

// ── Fit mode ─────────────────────────────────────────────────────────
typedef NS_ENUM(NSInteger, FitMode) {
    FitModeNone,
    FitModeWidth,
    FitModePage,
};

// ── PDF page view (the content inside the scroll view) ──────────────
@interface PDFPageView : NSView
@property (nonatomic, weak) MuPDFRenderer *renderer;
@property (nonatomic) NSUInteger pageNumber;
@property (nonatomic) CGFloat zoom;
@property (nonatomic) CGFloat backingScale;
- (void)renderPage;
@end

@implementation PDFPageView

- (instancetype)init {
    self = [super init];
    if (self) {
        self.wantsLayer = YES;
    }
    return self;
}

- (void)renderPage {
    if (!self.renderer) return;

    CGFloat scale = self.zoom * self.backingScale;
    CGImageRef image = [self.renderer newCGImageForPage:self.pageNumber scale:scale];
    if (!image) return;

    self.layer.contentsScale = self.backingScale;
    self.layer.contents = (__bridge id)image;

    NSSize size = NSMakeSize(CGImageGetWidth(image) / self.backingScale,
                              CGImageGetHeight(image) / self.backingScale);
    [self setFrameSize:size];

    CGImageRelease(image);
}

@end

// ── AppDelegate ──────────────────────────────────────────────────────
@interface AppDelegate () {
    CGFloat _shiftScrollAccum;
}
@property (strong) NSWindow *window;
@property (strong) NSScrollView *scrollView;
@property (strong) PDFPageView *pageView;
@property (strong) MuPDFRenderer *renderer;
@property (strong) NSTextField *pageField;
@property (strong) NSTextField *zoomField;
@property (nonatomic) NSUInteger currentPage;
@property (nonatomic) CGFloat zoomLevel;
@property (nonatomic) FitMode fitMode;
@end

@implementation AppDelegate

// ── Lifecycle ──────────────────────────────────────────────────────

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // ── Window ──
    NSRect frame = NSMakeRect(0, 0, 1000, 730);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskMiniaturizable |
                                                       NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"PDF Viewer";
    self.window.delegate = self;
    self.window.minSize = NSMakeSize(500, 350);

    // ── Toolbar ──
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"PDFViewerToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization = NO;
    self.window.toolbar = toolbar;

    // ── Scroll view ──
    self.scrollView = [[NSScrollView alloc] initWithFrame:self.window.contentView.bounds];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = YES;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.borderType = NSNoBorder;

    // ── Page view ──
    self.pageView = [[PDFPageView alloc] init];
    self.scrollView.documentView = self.pageView;

    [self.window.contentView addSubview:self.scrollView];

    // ── Gesture recognisers ──
    // Pinch-to-zoom
    NSMagnificationGestureRecognizer *pinch = [[NSMagnificationGestureRecognizer alloc]
                                                 initWithTarget:self action:@selector(handlePinch:)];
    [self.pageView addGestureRecognizer:pinch];

    // Shift + scroll wheel = zoom
    __weak __typeof(self) ws = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                         handler:^NSEvent *(NSEvent *event) {
        __typeof(self) ss = ws;
        if (ss && (event.modifierFlags & NSEventModifierFlagShift) && ss.renderer) {
            ss->_shiftScrollAccum += event.scrollingDeltaY;
            static const CGFloat kThreshold = 8.0;
            if (ss->_shiftScrollAccum > kThreshold) {
                [ss zoomInAction:nil];
                ss->_shiftScrollAccum = 0;
            } else if (ss->_shiftScrollAccum < -kThreshold) {
                [ss zoomOutAction:nil];
                ss->_shiftScrollAccum = 0;
            }
            return nil; // consume event, prevent scrolling
        }
        return event;
    }];

    // ── State ──
    self.currentPage = 0;
    self.zoomLevel = 1.0;
    self.fitMode = FitModeNone;

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];

    // Open file from command line (if provided)
    NSArray *args = [NSProcessInfo processInfo].arguments;
    if (args.count > 1) {
        [self openFileAtPath:args[1]];
    }
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    [self openFileAtPath:filename];
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    return NSTerminateNow;
}

// ── Window delegate ────────────────────────────────────────────────

- (void)windowDidResize:(NSNotification *)notification {
    [self applyFitMode];
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification {
    if (self.renderer) {
        self.pageView.backingScale = self.window.backingScaleFactor;
        [self renderCurrentPage];
    }
}

// ── File operations ───────────────────────────────────────────────

- (void)openFileAtPath:(NSString *)path {
    MuPDFRenderer *renderer = [[MuPDFRenderer alloc] initWithPath:path];
    if (!renderer) {
        [self showAlertWithTitle:@"Cannot Open File"
                         message:[NSString stringWithFormat:@"Failed to open:\n%@", path]];
        return;
    }

    // Close previous document
    if (self.renderer) {
        [self.renderer close];
    }

    self.renderer = renderer;
    self.currentPage = 0;
    self.zoomLevel = 1.0;
    self.fitMode = FitModeNone;
    self.pageView.renderer = renderer;
    self.pageView.backingScale = self.window.backingScaleFactor;
    self.pageView.pageNumber = 0;
    self.pageView.zoom = 1.0;

    [self renderCurrentPage];
    [self updateToolbarLabels];
    [self updateWindowTitle];
}

- (void)closeDocument {
    if (self.renderer) {
        [self.renderer close];
        self.renderer = nil;
    }
    self.pageView.renderer = nil;
    self.pageView.layer.contents = nil;
    [self.pageView setFrameSize:NSMakeSize(0, 0)];
    [self updateToolbarLabels];
    self.window.title = @"PDF Viewer";
}

// ── Rendering ──────────────────────────────────────────────────────

- (void)renderCurrentPage {
    if (!self.renderer) return;

    self.pageView.pageNumber = self.currentPage;
    self.pageView.zoom = self.zoomLevel;
    [self.pageView renderPage];

    [self updateToolbarLabels];
}

- (void)applyFitMode {
    if (!self.renderer || self.fitMode == FitModeNone) return;

    NSSize pageSize = [self.renderer pageSizeAtIndex:self.currentPage];
    if (pageSize.width <= 0 || pageSize.height <= 0) return;

    NSRect scrollBounds = self.scrollView.contentView.bounds;
    CGFloat vw = scrollBounds.size.width;
    CGFloat vh = scrollBounds.size.height;

    if (self.fitMode == FitModeWidth) {
        self.zoomLevel = vw / pageSize.width;
        [self renderCurrentPage];
    } else if (self.fitMode == FitModePage) {
        CGFloat zx = vw / pageSize.width;
        CGFloat zy = vh / pageSize.height;
        self.zoomLevel = MIN(zx, zy);
        [self renderCurrentPage];
    }
    [self updateToolbarLabels];
}

// ── Toolbar labels ────────────────────────────────────────────────

- (void)updateToolbarLabels {
    if (self.renderer) {
        self.pageField.stringValue = [NSString stringWithFormat:@"%lu", self.currentPage + 1];
        self.zoomField.stringValue = [NSString stringWithFormat:@"%ld%%",
                                       (long)lround(self.zoomLevel * 100)];
    } else {
        self.pageField.stringValue = @"-";
        self.zoomField.stringValue = @"-";
    }
}

- (void)updateWindowTitle {
    if (self.renderer) {
        NSString *name = [self.renderer.filePath lastPathComponent];
        self.window.title = [NSString stringWithFormat:@"%@ - PDF Viewer", name];
    } else {
        self.window.title = @"PDF Viewer";
    }
}

// ── Alert helper ──────────────────────────────────────────────────

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

// ════════════════════════════════════════════════════════════════════
//  TOOLBAR DELEGATE
// ════════════════════════════════════════════════════════════════════

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[
        kToolbarOpen,
        NSToolbarFlexibleSpaceItemIdentifier,
        kToolbarPrevPage,
        kToolbarPage,
        kToolbarNextPage,
        NSToolbarFlexibleSpaceItemIdentifier,
        kToolbarZoomOut,
        kToolbarZoom,
        kToolbarZoomIn,
        NSToolbarFlexibleSpaceItemIdentifier,
        kToolbarFitW,
        kToolbarFitP,
    ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
 willBeInsertedIntoToolbar:(BOOL)flag {

    // ── Open ──────────────────────────────────────────────────────
    if ([identifier isEqualToString:kToolbarOpen]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Open";
        item.paletteLabel = @"Open";
        item.image = [NSImage imageWithSystemSymbolName:@"folder"
                               accessibilityDescription:@"Open document"];
        item.target = self;
        item.action = @selector(openAction:);
        return item;
    }

    // ── Previous page ─────────────────────────────────────────────
    if ([identifier isEqualToString:kToolbarPrevPage]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Prev";
        item.paletteLabel = @"Previous Page";
        item.image = [NSImage imageWithSystemSymbolName:@"chevron.left"
                               accessibilityDescription:@"Previous page"];
        item.target = self;
        item.action = @selector(prevPageAction:);
        return item;
    }

    // ── Page number field ─────────────────────────────────────────
    if ([identifier isEqualToString:kToolbarPage]) {
        self.pageField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 56, 22)];
        self.pageField.stringValue = @"-";
        self.pageField.alignment = NSTextAlignmentCenter;
        self.pageField.placeholderString = @"Page";
        self.pageField.target = self;
        self.pageField.action = @selector(pageFieldAction:);
        self.pageField.delegate = self;

        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.view = self.pageField;
        item.label = @"Page";
        return item;
    }

    // ── Next page ─────────────────────────────────────────────────
    if ([identifier isEqualToString:kToolbarNextPage]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Next";
        item.paletteLabel = @"Next Page";
        item.image = [NSImage imageWithSystemSymbolName:@"chevron.right"
                               accessibilityDescription:@"Next page"];
        item.target = self;
        item.action = @selector(nextPageAction:);
        return item;
    }

    // ── Zoom out ──────────────────────────────────────────────────
    if ([identifier isEqualToString:kToolbarZoomOut]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Zoom Out";
        item.image = [NSImage imageWithSystemSymbolName:@"minus.magnifyingglass"
                               accessibilityDescription:@"Zoom out"];
        item.target = self;
        item.action = @selector(zoomOutAction:);
        return item;
    }

    // ── Zoom label ────────────────────────────────────────────────
    if ([identifier isEqualToString:kToolbarZoom]) {
        self.zoomField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 48, 22)];
        self.zoomField.stringValue = @"100%";
        self.zoomField.alignment = NSTextAlignmentCenter;
        self.zoomField.editable = NO;
        self.zoomField.bezeled = NO;
        self.zoomField.drawsBackground = NO;
        self.zoomField.selectable = NO;

        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.view = self.zoomField;
        item.label = @"Zoom";
        return item;
    }

    // ── Zoom in ───────────────────────────────────────────────────
    if ([identifier isEqualToString:kToolbarZoomIn]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Zoom In";
        item.image = [NSImage imageWithSystemSymbolName:@"plus.magnifyingglass"
                               accessibilityDescription:@"Zoom in"];
        item.target = self;
        item.action = @selector(zoomInAction:);
        return item;
    }

    // ── Fit width ─────────────────────────────────────────────────
    if ([identifier isEqualToString:kToolbarFitW]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Fit Width";
        item.target = self;
        item.action = @selector(fitWidthAction:);
        return item;
    }

    // ── Fit page ──────────────────────────────────────────────────
    if ([identifier isEqualToString:kToolbarFitP]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = @"Fit Page";
        item.target = self;
        item.action = @selector(fitPageAction:);
        return item;
    }

    return nil;
}

// ════════════════════════════════════════════════════════════════════
//  ACTIONS
// ════════════════════════════════════════════════════════════════════

- (void)openAction:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"pdf"]];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            [self openFileAtPath:panel.URL.path];
        }
    }];
}

- (void)prevPageAction:(id)sender {
    if (!self.renderer || self.currentPage == 0) return;
    self.currentPage--;
    self.fitMode = FitModeNone;
    [self renderCurrentPage];
}

- (void)nextPageAction:(id)sender {
    if (!self.renderer || self.currentPage + 1 >= self.renderer.pageCount) return;
    self.currentPage++;
    self.fitMode = FitModeNone;
    [self renderCurrentPage];
}

- (void)pageFieldAction:(id)sender {
    if (!self.renderer) return;
    NSInteger page = [self.pageField integerValue];
    if (page < 1 || (NSUInteger)page > self.renderer.pageCount) return;
    self.currentPage = (NSUInteger)(page - 1);
    self.fitMode = FitModeNone;
    [self renderCurrentPage];
}

- (void)zoomInAction:(id)sender {
    if (!self.renderer) return;
    self.fitMode = FitModeNone;
    self.zoomLevel = MIN(self.zoomLevel * 1.25, 20.0);
    [self renderCurrentPage];
}

- (void)zoomOutAction:(id)sender {
    if (!self.renderer) return;
    self.fitMode = FitModeNone;
    self.zoomLevel = MAX(self.zoomLevel / 1.25, 0.1);
    [self renderCurrentPage];
}

- (void)fitWidthAction:(id)sender {
    if (!self.renderer) return;
    self.fitMode = FitModeWidth;
    [self applyFitMode];
}

- (void)fitPageAction:(id)sender {
    if (!self.renderer) return;
    self.fitMode = FitModePage;
    [self applyFitMode];
}

// ════════════════════════════════════════════════════════════════════
//  GESTURES
// ════════════════════════════════════════════════════════════════════

- (void)handlePinch:(NSMagnificationGestureRecognizer *)sender {
    if (!self.renderer) return;

    if (sender.state == NSGestureRecognizerStateChanged) {
        CGFloat factor = 1.0 + sender.magnification;
        self.zoomLevel = MAX(MIN(self.zoomLevel * factor, 20.0), 0.1);
        self.fitMode = FitModeNone;
        [self renderCurrentPage];
        sender.magnification = 0.0;
    }
}

// ════════════════════════════════════════════════════════════════════
//  NSTextField DELEGATE (Enter key in page field)
// ════════════════════════════════════════════════════════════════════

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(insertNewline:)) {
        [self pageFieldAction:control];
        return YES;
    }
    return NO;
}

// ════════════════════════════════════════════════════════════════════
//  MENU ACTIONS (support standard shortcuts)
// ════════════════════════════════════════════════════════════════════

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(openAction:))  return YES;
    if (menuItem.action == @selector(prevPageAction:)) return self.renderer != nil && self.currentPage > 0;
    if (menuItem.action == @selector(nextPageAction:)) return self.renderer != nil && self.currentPage + 1 < self.renderer.pageCount;
    if (menuItem.action == @selector(zoomInAction:))  return self.renderer != nil;
    if (menuItem.action == @selector(zoomOutAction:)) return self.renderer != nil;
    return YES;
}

@end
