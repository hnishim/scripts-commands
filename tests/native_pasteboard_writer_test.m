#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <stdio.h>

static NSString *gPlainText;
static NSData *gHTMLData;
static BOOL gPasteboardWritten;

@interface HIR11TestPasteboardItem : NSObject
@property(nonatomic, copy) NSString *plainText;
@property(nonatomic, copy) NSData *htmlData;
- (BOOL)setString:(NSString *)string forType:(NSString *)type;
- (BOOL)setData:(NSData *)data forType:(NSString *)type;
@end

@interface HIR11TestPasteboard : NSObject
+ (instancetype)generalPasteboard;
- (void)clearContents;
- (BOOL)writeObjects:(NSArray *)objects;
@end

#define NSPasteboard HIR11TestPasteboard
#define NSPasteboardItem HIR11TestPasteboardItem
#define NSPasteboardTypeString @"hir11.test.plain-text"
#define NSPasteboardTypeHTML @"hir11.test.html"
#define main HIR11NotionHelperMain
#include "../notion-current-page-accessibility.m"
#undef main
#undef NSPasteboardTypeHTML
#undef NSPasteboardTypeString
#undef NSPasteboardItem
#undef NSPasteboard

@implementation HIR11TestPasteboardItem

- (BOOL)setString:(NSString *)string forType:(NSString *)type {
    if (![type isEqualToString:@"hir11.test.plain-text"]) return NO;
    self.plainText = string;
    return YES;
}

- (BOOL)setData:(NSData *)data forType:(NSString *)type {
    if (![type isEqualToString:@"hir11.test.html"]) return NO;
    self.htmlData = data;
    return YES;
}

@end

@implementation HIR11TestPasteboard

+ (instancetype)generalPasteboard {
    static HIR11TestPasteboard *pasteboard;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pasteboard = [[HIR11TestPasteboard alloc] init];
    });
    return pasteboard;
}

- (void)clearContents {
    gPlainText = nil;
    gHTMLData = nil;
    gPasteboardWritten = NO;
}

- (BOOL)writeObjects:(NSArray *)objects {
    if (objects.count != 1
            || ![objects.firstObject isKindOfClass:[HIR11TestPasteboardItem class]]) {
        return NO;
    }
    HIR11TestPasteboardItem *item = objects.firstObject;
    gPlainText = [item.plainText copy];
    gHTMLData = [item.htmlData copy];
    gPasteboardWritten = gPlainText != nil && gHTMLData != nil;
    return gPasteboardWritten;
}

@end

int main(void) {
    @autoreleasepool {
        int result = WritePasteboardPayload();
        if (result != 0 || !gPasteboardWritten || !gPlainText || !gHTMLData) {
            fprintf(stderr, "pasteboard writer failed: result=%d written=%d plain=%d html=%d\n",
                    result, gPasteboardWritten, gPlainText != nil, gHTMLData != nil);
            return 1;
        }

        NSString *html = [[NSString alloc] initWithData:gHTMLData
                                                encoding:NSUTF8StringEncoding];
        if (!html || ![html containsString:@"<meta charset=\"utf-8\">"]
                || ![html containsString:@"日本語タイトル"]
                || ![gPlainText containsString:@"日本語タイトル"]) {
            fprintf(stderr, "formatted pasteboard HTML did not preserve UTF-8 text\n");
            return 1;
        }

        printf("HIR11_NATIVE_PASTEBOARD_WRITER_TESTS:PASS\n");
        return 0;
    }
}
