#import <Cocoa/Cocoa.h>
#include <mupdf/fitz.h>

NS_ASSUME_NONNULL_BEGIN

@interface MuPDFRenderer : NSObject

- (nullable instancetype)initWithPath:(NSString *)path;
@property (nonatomic, readonly) NSUInteger pageCount;
@property (nonatomic, readonly) NSString *filePath;

- (NSSize)pageSizeAtIndex:(NSUInteger)index;
- (nullable CGImageRef)newCGImageForPage:(NSUInteger)pageNumber scale:(CGFloat)scale CF_RETURNS_RETAINED;
- (void)close;

@end

NS_ASSUME_NONNULL_END
