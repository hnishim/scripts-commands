#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdarg.h>
#include <string.h>

@interface HIR11TestRunningApplication : NSObject
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic) pid_t processIdentifier;
@end

@interface HIR11TestWorkspace : NSObject
@property(nonatomic, strong) HIR11TestRunningApplication *frontmostApplication;
+ (instancetype)sharedWorkspace;
@end

static AXError HIR11TestCopyMultipleAttributeValues(
    AXUIElementRef element,
    CFArrayRef attributes,
    AXCopyMultipleAttributeOptions options,
    CFArrayRef *values);
static AXError HIR11TestCopyAttributeValue(
    AXUIElementRef element,
    CFStringRef attribute,
    CFTypeRef *value);
static void HIR11TestSetMessagingTimeout(AXUIElementRef element, Float32 timeout);
static AXUIElementRef HIR11TestCreateApplication(pid_t pid);
static int HIR11TestFprintf(FILE *stream, const char *format, ...);
static NSString *gTestFailureStage;

#define NSRunningApplication HIR11TestRunningApplication
#define NSWorkspace HIR11TestWorkspace
#define AXUIElementCopyMultipleAttributeValues HIR11TestCopyMultipleAttributeValues
#define AXUIElementCopyAttributeValue HIR11TestCopyAttributeValue
#define AXUIElementSetMessagingTimeout HIR11TestSetMessagingTimeout
#define AXUIElementCreateApplication HIR11TestCreateApplication
#define AXUIElementGetTypeID() CFDataGetTypeID()
#define fprintf HIR11TestFprintf
#define main HIR11NativeHelperMain
#include "../notion-current-page-accessibility.m"
#undef main
#undef fprintf
#undef AXUIElementGetTypeID
#undef AXUIElementCreateApplication
#undef AXUIElementSetMessagingTimeout
#undef AXUIElementCopyAttributeValue
#undef AXUIElementCopyMultipleAttributeValues
#undef NSWorkspace
#undef NSRunningApplication

static NSMutableDictionary<NSString *, NSDictionary *> *gTestNodes;
static NSMutableDictionary<NSString *, id> *gTestTokens;
static NSMutableSet<NSString *> *gTestAttributeQueries;

@implementation HIR11TestWorkspace

+ (instancetype)sharedWorkspace {
    static HIR11TestWorkspace *workspace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        workspace = [[HIR11TestWorkspace alloc] init];
        workspace.frontmostApplication = [[HIR11TestRunningApplication alloc] init];
        workspace.frontmostApplication.bundleIdentifier = @"notion.id";
        workspace.frontmostApplication.processIdentifier = 42;
    });
    return workspace;
}

@end

@implementation HIR11TestRunningApplication
@end

static NSString *HIR11TestElementKey(CFTypeRef element) {
    if (!element || CFGetTypeID(element) != CFDataGetTypeID()) return nil;
    CFDataRef data = (CFDataRef)element;
    return [[NSString alloc] initWithBytes:CFDataGetBytePtr(data)
                                    length:CFDataGetLength(data)
                                  encoding:NSUTF8StringEncoding];
}

static id HIR11TestAttribute(CFTypeRef element, CFStringRef attribute) {
    NSString *elementKey = HIR11TestElementKey(element);
    NSString *attributeKey = (__bridge NSString *)attribute;
    if (elementKey && attributeKey) {
        [gTestAttributeQueries addObject:[NSString stringWithFormat:@"%@.%@", elementKey, attributeKey]];
    }
    id value = gTestNodes[elementKey][attributeKey];
    return value == NSNull.null ? nil : value;
}

static AXError HIR11TestCopyMultipleAttributeValues(
    AXUIElementRef element,
    CFArrayRef attributes,
    AXCopyMultipleAttributeOptions options,
    CFArrayRef *values) {
    (void)options;
    if (!attributes || CFArrayGetCount(attributes) != 1 || !values) {
        return kAXErrorIllegalArgument;
    }
    CFStringRef attribute = (CFStringRef)CFArrayGetValueAtIndex(attributes, 0);
    id value = HIR11TestAttribute((CFTypeRef)element, attribute);
    if (!value) return kAXErrorAttributeUnsupported;
    const void *items[] = {(__bridge CFTypeRef)value};
    *values = CFArrayCreate(kCFAllocatorDefault, items, 1, &kCFTypeArrayCallBacks);
    return *values ? kAXErrorSuccess : kAXErrorFailure;
}

static AXError HIR11TestCopyAttributeValue(
    AXUIElementRef element,
    CFStringRef attribute,
    CFTypeRef *value) {
    if (!value) return kAXErrorIllegalArgument;
    id result = HIR11TestAttribute((CFTypeRef)element, attribute);
    if (!result) return kAXErrorAttributeUnsupported;
    *value = CFRetain((__bridge CFTypeRef)result);
    return kAXErrorSuccess;
}

static void HIR11TestSetMessagingTimeout(AXUIElementRef element, Float32 timeout) {
    (void)element;
    (void)timeout;
}

static AXUIElementRef HIR11TestCreateApplication(pid_t pid) {
    (void)pid;
    CFDataRef token = (__bridge CFDataRef)gTestTokens[@"application"];
    return (AXUIElementRef)CFRetain(token);
}

static int HIR11TestFprintf(FILE *stream, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    va_list outputArguments;
    va_copy(outputArguments, arguments);
    if (strcmp(format, "HIR11_STAGE:%s\n") == 0) {
        const char *stage = va_arg(arguments, const char *);
        gTestFailureStage = [NSString stringWithUTF8String:stage];
    }
    int result = vfprintf(stream, format, outputArguments);
    va_end(outputArguments);
    va_end(arguments);
    return result;
}

static void HIR11TestAddElement(NSString *key, NSDictionary *attributes) {
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    gTestTokens[key] = data;
    gTestNodes[key] = attributes;
}

static id HIR11TestToken(NSString *key) {
    id token = gTestTokens[key];
    if (!token) {
        token = [key dataUsingEncoding:NSUTF8StringEncoding];
        gTestTokens[key] = token;
    }
    return token;
}

static void HIR11TestBuildFixture(BOOL selectedHasSidePeek,
                                  BOOL unselectedHasSidePeek,
                                  NSString *windowTitle,
                                  BOOL duplicateSelectedTitle) {
    gTestNodes = [NSMutableDictionary dictionary];
    gTestTokens = [NSMutableDictionary dictionary];
    gTestAttributeQueries = [NSMutableSet set];
    gTestFailureStage = nil;

    HIR11TestAddElement(@"application", @{
        @"AXFocusedWindow": HIR11TestToken(@"window") ?: NSNull.null
    });
    HIR11TestAddElement(@"window", @{
        @"AXRole": @"AXWindow",
        @"AXTitle": windowTitle,
        @"AXChildren": @[HIR11TestToken(@"tabs") ?: NSNull.null],
        @"AXVisibleChildren": NSNull.null
    });
    HIR11TestAddElement(@"tabs", @{
        @"AXRole": @"AXGroup",
        @"AXChildren": @[
            HIR11TestToken(@"selected") ?: NSNull.null,
            HIR11TestToken(@"unselected") ?: NSNull.null,
            HIR11TestToken(@"duplicate") ?: NSNull.null
        ],
        @"AXVisibleChildren": @[
            HIR11TestToken(@"selected") ?: NSNull.null,
            HIR11TestToken(@"unselected") ?: NSNull.null
        ]
    });

    NSArray *selectedChildren = selectedHasSidePeek
        ? @[HIR11TestToken(@"selected-scope") ?: NSNull.null] : @[];
    NSArray *unselectedChildren = unselectedHasSidePeek
        ? @[HIR11TestToken(@"unselected-scope") ?: NSNull.null] : @[];
    HIR11TestAddElement(@"selected", @{
        @"AXRole": @"AXWebArea",
        @"AXTitle": @"Selected page",
        @"AXURL": @"https://www.notion.so/selected-page-id",
        @"AXChildren": selectedChildren,
        @"AXVisibleChildren": selectedChildren
    });
    HIR11TestAddElement(@"unselected", @{
        @"AXRole": @"AXWebArea",
        @"AXTitle": @"Other page",
        @"AXURL": @"https://www.notion.so/other-page-id",
        @"AXChildren": unselectedChildren,
        @"AXVisibleChildren": unselectedChildren
    });
    HIR11TestAddElement(@"duplicate", @{
        @"AXRole": @"AXWebArea",
        @"AXTitle": duplicateSelectedTitle ? @"Selected page" : @"Duplicate page",
        @"AXURL": @"https://www.notion.so/duplicate-page-id",
        @"AXChildren": @[],
        @"AXVisibleChildren": @[]
    });

    HIR11TestAddElement(@"selected-scope", @{
        @"AXRole": @"AXGroup",
        @"AXTitle": @"Side Peek",
        @"AXChildren": @[HIR11TestToken(@"selected-child") ?: NSNull.null],
        @"AXVisibleChildren": @[HIR11TestToken(@"selected-child") ?: NSNull.null]
    });
    HIR11TestAddElement(@"selected-child", @{
        @"AXRole": @"AXWebArea",
        @"AXTitle": @"Selected child",
        @"AXChildren": @[HIR11TestToken(@"selected-link") ?: NSNull.null],
        @"AXVisibleChildren": @[HIR11TestToken(@"selected-link") ?: NSNull.null]
    });
    HIR11TestAddElement(@"selected-link", @{
        @"AXRole": @"AXLink",
        @"AXDescription": @"Open in full page",
        @"AXURL": @"https://app.notion.com/p/example/89abcdef0123456789abcdef01234567?pvs=23"
    });
    HIR11TestAddElement(@"unselected-scope", @{
        @"AXRole": @"AXGroup",
        @"AXTitle": @"Side Peek",
        @"AXChildren": @[HIR11TestToken(@"unselected-child") ?: NSNull.null],
        @"AXVisibleChildren": @[HIR11TestToken(@"unselected-child") ?: NSNull.null]
    });
    HIR11TestAddElement(@"unselected-child", @{
        @"AXRole": @"AXWebArea",
        @"AXTitle": @"Other child",
        @"AXChildren": @[HIR11TestToken(@"unselected-link") ?: NSNull.null],
        @"AXVisibleChildren": @[HIR11TestToken(@"unselected-link") ?: NSNull.null]
    });
    HIR11TestAddElement(@"unselected-link", @{
        @"AXRole": @"AXLink",
        @"AXDescription": @"Open in full page",
        @"AXURL": @"https://app.notion.com/p/example/0123456789abcdef0123456789abcdef?pvs=23"
    });
}

static int HIR11TestRunScenario(BOOL selectedHasSidePeek,
                               BOOL unselectedHasSidePeek,
                               NSString *windowTitle,
                               BOOL duplicateSelectedTitle,
                               NSString *expectedFailure,
                               NSString *expectedTitle) {
    HIR11TestBuildFixture(selectedHasSidePeek, unselectedHasSidePeek,
                          windowTitle, duplicateSelectedTitle);
    gDeadline = CFAbsoluteTimeGetCurrent() + 5.0;
    gFailureStage = "accessibility_read_failed";
    int result = EmitFocusedPageSnapshot();
    if (![gTestAttributeQueries containsObject:@"window.AXChildren"]) {
        fprintf(stderr, "window AXChildren was not queried\n");
        return 1;
    }
    if ([gTestAttributeQueries containsObject:@"unselected.AXVisibleChildren"]) {
        fprintf(stderr, "unselected tab content was traversed\n");
        return 1;
    }
    if (expectedFailure) {
        if (result == 0 || !gTestFailureStage || ![gTestFailureStage isEqualToString:expectedFailure]) {
            fprintf(stderr, "expected fail-closed stage %s; got %s\n",
                    expectedFailure.UTF8String,
                    gTestFailureStage.UTF8String ?: "none");
            return 1;
        }
        return 0;
    }
    if (result != 0) {
        fprintf(stderr, "expected selected page %s; got failure %s\n",
                expectedTitle.UTF8String,
                gTestFailureStage.UTF8String ?: "none");
        return 1;
    }
    return 0;
}

int main(void) {
    @autoreleasepool {
        int failures = 0;
        failures += HIR11TestRunScenario(NO, YES, @"Selected page", NO, nil, @"Selected page");
        failures += HIR11TestRunScenario(YES, YES, @"Selected page", NO, nil, @"Selected child");
        failures += HIR11TestRunScenario(NO, YES, @"No matching page", NO,
                                         @"page_area_missing", nil);
        failures += HIR11TestRunScenario(NO, YES, @"Selected page", YES,
                                         @"page_area_ambiguous", nil);
        if (failures == 0) fprintf(stderr, "HIR11_NATIVE_AX_SELECTION_TESTS:PASS:4\n");
        return failures == 0 ? 0 : 1;
    }
}
