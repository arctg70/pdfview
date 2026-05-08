#import "MuPDFRenderer.h"

@interface MuPDFRenderer ()
@property fz_context *ctx;
@property fz_document *doc;
@end

@implementation MuPDFRenderer

- (void)dealloc {
    [self close];
}

- (nullable instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;

    _filePath = [path copy];

    _ctx = fz_new_context(NULL, NULL, FZ_STORE_UNLIMITED);
    if (!_ctx) {
        NSLog(@"Failed to create MuPDF context");
        return nil;
    }

    __block BOOL success = YES;

    fz_try(_ctx) {
        fz_register_document_handlers(_ctx);
    } fz_catch(_ctx) {
        fz_report_error(_ctx);
        success = NO;
    }
    if (!success) {
        fz_drop_context(_ctx);
        _ctx = NULL;
        return nil;
    }

    fz_try(_ctx) {
        _doc = fz_open_document(_ctx, [path UTF8String]);
    } fz_catch(_ctx) {
        fz_report_error(_ctx);
        success = NO;
    }
    if (!success || !_doc) {
        fz_drop_context(_ctx);
        _ctx = NULL;
        return nil;
    }

    return self;
}

- (NSUInteger)pageCount {
    return (NSUInteger)fz_count_pages(_ctx, _doc);
}

- (NSSize)pageSizeAtIndex:(NSUInteger)index {
    fz_page *page = fz_load_page(_ctx, _doc, (int)index);
    if (!page) return NSMakeSize(595, 842);

    __block fz_rect bounds;
    fz_try(_ctx) {
        bounds = fz_bound_page(_ctx, page);
    } fz_catch(_ctx) {
        fz_report_error(_ctx);
        fz_drop_page(_ctx, page);
        return NSMakeSize(595, 842);
    }
    fz_drop_page(_ctx, page);

    return NSMakeSize(bounds.x1 - bounds.x0, bounds.y1 - bounds.y0);
}

- (nullable CGImageRef)newCGImageForPage:(NSUInteger)pageNumber scale:(CGFloat)scale {
    if (!_doc || !_ctx) return NULL;

    fz_matrix ctm = fz_scale(scale, scale);
    fz_colorspace *cs = fz_device_rgb(_ctx);

    fz_page *page = NULL;
    fz_pixmap *pix = NULL;

    __block BOOL success = YES;

    fz_try(_ctx) {
        page = fz_load_page(_ctx, _doc, (int)pageNumber);
    } fz_catch(_ctx) {
        fz_report_error(_ctx);
        success = NO;
    }
    if (!success || !page) return NULL;

    fz_try(_ctx) {
        pix = fz_new_pixmap_from_page(_ctx, page, ctm, cs, 0);
    } fz_catch(_ctx) {
        fz_report_error(_ctx);
        fz_drop_page(_ctx, page);
        success = NO;
    }
    fz_drop_page(_ctx, page);

    if (!success || !pix) return NULL;

    int w = pix->w;
    int h = pix->h;
    int stride = pix->stride;
    unsigned char *samples = pix->samples;

    if (w <= 0 || h <= 0) {
        fz_drop_pixmap(_ctx, pix);
        return NULL;
    }

    // Copy pixel data so we can free the pixmap immediately
    NSData *data = [[NSData alloc] initWithBytes:samples length:(NSUInteger)(stride * h)];
    fz_drop_pixmap(_ctx, pix);

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef rgbCS = CGColorSpaceCreateDeviceRGB();
    CGImageRef cgImage = CGImageCreate(
        w, h,
        8,                     // bitsPerComponent
        24,                    // bitsPerPixel
        stride,                // bytesPerRow
        rgbCS,
        kCGBitmapByteOrderDefault | kCGImageAlphaNone,
        provider,
        NULL,
        NO,
        kCGRenderingIntentDefault
    );

    CGDataProviderRelease(provider);
    CGColorSpaceRelease(rgbCS);

    return cgImage;
}

- (void)close {
    if (_doc) {
        fz_drop_document(_ctx, _doc);
        _doc = NULL;
    }
    if (_ctx) {
        fz_drop_context(_ctx);
        _ctx = NULL;
    }
}

@end
