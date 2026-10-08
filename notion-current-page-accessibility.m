#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>

static CFAbsoluteTime gDeadline;
static const char *gFailureStage = "accessibility_read_failed";

static int Fail(const char *stage) {
    fprintf(stderr, "HIR11_STAGE:%s\n", stage);
    return 1;
}

static CFTypeRef CopyAttribute(AXUIElementRef element, CFStringRef attribute) {
    if (CFAbsoluteTimeGetCurrent() >= gDeadline) {
        gFailureStage = "accessibility_timeout";
        return NULL;
    }

    AXUIElementSetMessagingTimeout(element, 0.5);
    const void *requestedAttributes[] = {attribute};
    CFArrayRef attributes = CFArrayCreate(
        kCFAllocatorDefault, requestedAttributes, 1, &kCFTypeArrayCallBacks);
    if (!attributes) return NULL;

    CFArrayRef values = NULL;
    AXError error = AXUIElementCopyMultipleAttributeValues(
        element, attributes, kAXCopyMultipleAttributeOptionStopOnError, &values);
    CFRelease(attributes);
    if (error != kAXErrorSuccess || !values || CFArrayGetCount(values) != 1) {
        if (values) CFRelease(values);
        return NULL;
    }

    CFTypeRef value = CFArrayGetValueAtIndex(values, 0);
    if (value) CFRetain(value);
    CFRelease(values);
    return value;
}

static CFStringRef CopyStringAttribute(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = CopyAttribute(element, attribute);
    if (!value) return NULL;
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return NULL;
    }
    return (CFStringRef)value;
}

static CFStringRef CopyURLAttribute(AXUIElementRef element) {
    const CFStringRef attributes[] = {kAXURLAttribute, kAXValueAttribute};
    for (NSUInteger i = 0; i < sizeof(attributes) / sizeof(attributes[0]); i++) {
        CFTypeRef value = CopyAttribute(element, attributes[i]);
        if (!value) continue;
        if (CFGetTypeID(value) == CFStringGetTypeID()) return (CFStringRef)value;
        if (CFGetTypeID(value) == CFURLGetTypeID()) {
            CFStringRef string = CFURLGetString((CFURLRef)value);
            if (string) CFRetain(string);
            CFRelease(value);
            if (string) return string;
            continue;
        }
        CFRelease(value);
    }
    return NULL;
}

static BOOL IsFullPageLabel(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return NO;
    NSString *label = [(__bridge NSString *)value
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *accepted = @[
        @"Open as full page", @"Open in full page", @"全ページで開く", @"フルページで開く"
    ];
    for (NSString *candidate in accepted) {
        if ([label caseInsensitiveCompare:candidate] == NSOrderedSame) return YES;
    }
    return NO;
}

static BOOL IsSidePeekScope(AXUIElementRef element) {
    const CFStringRef attributes[] = {kAXTitleAttribute, kAXDescriptionAttribute};
    for (NSUInteger i = 0; i < sizeof(attributes) / sizeof(attributes[0]); i++) {
        CFTypeRef value = CopyAttribute(element, attributes[i]);
        BOOL matches = NO;
        if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
            NSString *label = [(__bridge NSString *)value
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            matches = [label caseInsensitiveCompare:@"Side Peek"] == NSOrderedSame;
        }
        if (value) CFRelease(value);
        if (matches) return YES;
    }
    return NO;
}

static BOOL CopyFullPageLink(AXUIElementRef element,
                             CFStringRef *labelOut,
                             CFStringRef *urlOut) {
    CFStringRef role = CopyStringAttribute(element, kAXRoleAttribute);
    BOOL isLink = role && CFEqual(role, CFSTR("AXLink"));
    if (role) CFRelease(role);
    if (!isLink) return NO;

    const CFStringRef labelAttributes[] = {
        kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute
    };
    CFStringRef label = NULL;
    for (NSUInteger i = 0; i < sizeof(labelAttributes) / sizeof(labelAttributes[0]); i++) {
        CFTypeRef value = CopyAttribute(element, labelAttributes[i]);
        BOOL matches = IsFullPageLabel(value);
        if (matches && CFGetTypeID(value) == CFStringGetTypeID()) {
            label = (CFStringRef)value;
            break;
        }
        if (value) CFRelease(value);
    }
    if (!label) return NO;

    CFStringRef url = CopyURLAttribute(element);
    if (!url) {
        CFRelease(label);
        return NO;
    }
    *labelOut = label;
    *urlOut = url;
    return YES;
}

static int CopyFullPageLinkFromAncestors(AXUIElementRef webArea,
                                         CFStringRef *labelOut,
                                         CFStringRef *urlOut) {
    AXUIElementRef scope = (AXUIElementRef)CFRetain(webArea);
    CFStringRef matchedLabel = NULL;
    CFStringRef matchedURL = NULL;
    NSUInteger totalMatches = 0;
    for (NSUInteger depth = 0; scope && depth < 5; depth++) {
        CFTypeRef childrenValue = CopyAttribute(scope, kAXChildrenAttribute);
        if (childrenValue && CFGetTypeID(childrenValue) == CFArrayGetTypeID()) {
            CFArrayRef children = (CFArrayRef)childrenValue;
            CFIndex childCount = CFArrayGetCount(children);
            if (childCount <= 128) {
                for (CFIndex i = 0; i < childCount; i++) {
                    CFTypeRef childValue = CFArrayGetValueAtIndex(children, i);
                    if (!childValue || CFGetTypeID(childValue) != AXUIElementGetTypeID()) continue;
                    CFStringRef label = NULL;
                    CFStringRef url = NULL;
                    if (CopyFullPageLink((AXUIElementRef)childValue, &label, &url)) {
                        totalMatches++;
                        if (totalMatches == 1) {
                            matchedLabel = label;
                            matchedURL = url;
                        } else {
                            CFRelease(label);
                            CFRelease(url);
                        }
                    }
                }
                CFRelease(childrenValue);
            } else {
                CFRelease(childrenValue);
                if (matchedLabel) CFRelease(matchedLabel);
                if (matchedURL) CFRelease(matchedURL);
                CFRelease(scope);
                gFailureStage = "page_link_search_limit";
                return -1;
            }
        } else if (childrenValue) {
            CFRelease(childrenValue);
        }

        if (totalMatches > 1) {
            if (matchedLabel) CFRelease(matchedLabel);
            if (matchedURL) CFRelease(matchedURL);
            CFRelease(scope);
            gFailureStage = "page_link_ambiguous";
            return -1;
        }

        CFStringRef scopeRole = CopyStringAttribute(scope, kAXRoleAttribute);
        BOOL reachedWindow = scopeRole && CFEqual(scopeRole, CFSTR("AXWindow"));
        if (scopeRole) CFRelease(scopeRole);
        if (reachedWindow || IsSidePeekScope(scope) || depth == 4) break;

        CFTypeRef parentValue = CopyAttribute(scope, kAXParentAttribute);
        if (!parentValue || CFGetTypeID(parentValue) != AXUIElementGetTypeID()) {
            if (parentValue) CFRelease(parentValue);
            break;
        }
        AXUIElementRef parent = (AXUIElementRef)parentValue;
        if (CFEqual(scope, parent)) {
            CFRelease(parent);
            break;
        }
        CFRelease(scope);
        scope = parent;
    }
    if (scope) CFRelease(scope);
    if (totalMatches == 1) {
        *labelOut = matchedLabel;
        *urlOut = matchedURL;
        return 1;
    }
    return 0;
}

static AXUIElementRef CopyAncestorWithRole(AXUIElementRef element, CFStringRef targetRole) {
    AXUIElementRef current = (AXUIElementRef)CFRetain(element);
    for (NSUInteger depth = 0; current && depth < 64; depth++) {
        CFStringRef role = CopyStringAttribute(current, kAXRoleAttribute);
        BOOL matches = role && CFEqual(role, targetRole);
        if (role) CFRelease(role);
        if (matches) return current;

        CFTypeRef parentValue = CopyAttribute(current, kAXParentAttribute);
        if (!parentValue || CFGetTypeID(parentValue) != AXUIElementGetTypeID()) {
            if (parentValue) CFRelease(parentValue);
            break;
        }
        AXUIElementRef parent = (AXUIElementRef)parentValue;
        if (CFEqual(current, parent)) {
            CFRelease(parent);
            break;
        }
        CFRelease(current);
        current = parent;
    }
    if (current) CFRelease(current);
    return NULL;
}

static BOOL WalkForSidePeekScopes(AXUIElementRef element,
                                  NSUInteger depth,
                                  NSUInteger *visited,
                                  NSMutableArray *matches) {
    if (CFAbsoluteTimeGetCurrent() >= gDeadline) {
        gFailureStage = "accessibility_timeout";
        return NO;
    }
    if (depth > 32 || ++(*visited) > 512) {
        gFailureStage = "side_peek_scope_search_limit";
        return NO;
    }
    if (IsSidePeekScope(element)) {
        [matches addObject:CFBridgingRelease(CFRetain(element))];
        return YES;
    }

    CFStringRef role = CopyStringAttribute(element, kAXRoleAttribute);
    BOOL isPageArea = role && CFEqual(role, CFSTR("AXWebArea"));
    if (role) CFRelease(role);
    if (isPageArea) {
        CFStringRef title = CopyStringAttribute(element, kAXTitleAttribute);
        BOOL hasPageTitle = title && CFStringGetLength(title) > 0;
        if (title) CFRelease(title);
        if (hasPageTitle) return YES;
    }

    CFTypeRef childrenValue = CopyAttribute(element, kAXChildrenAttribute);
    if (gFailureStage && strcmp(gFailureStage, "accessibility_timeout") == 0) return NO;
    if (!childrenValue) return YES;
    if (CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
        CFRelease(childrenValue);
        return YES;
    }

    CFArrayRef children = (CFArrayRef)childrenValue;
    CFIndex childCount = CFArrayGetCount(children);
    if (childCount > 512) {
        CFRelease(childrenValue);
        gFailureStage = "side_peek_scope_search_limit";
        return NO;
    }
    for (CFIndex i = 0; i < childCount; i++) {
        CFTypeRef childValue = CFArrayGetValueAtIndex(children, i);
        if (!childValue || CFGetTypeID(childValue) != AXUIElementGetTypeID()) continue;
        if (!WalkForSidePeekScopes((AXUIElementRef)childValue, depth + 1, visited, matches)) {
            CFRelease(childrenValue);
            return NO;
        }
    }
    CFRelease(childrenValue);
    return YES;
}

static BOOL WalkForSidePeekPageAreas(AXUIElementRef sidePeekScope,
                                     AXUIElementRef element,
                                     NSUInteger depth,
                                     NSUInteger *visited,
                                     NSMutableArray *pageAreas) {
    if (CFAbsoluteTimeGetCurrent() >= gDeadline) {
        gFailureStage = "accessibility_timeout";
        return NO;
    }
    if (depth > 32 || ++(*visited) > 512) {
        gFailureStage = "side_peek_page_search_limit";
        return NO;
    }

    if (!CFEqual(element, sidePeekScope)) {
        CFStringRef role = CopyStringAttribute(element, kAXRoleAttribute);
        BOOL isPageArea = role && CFEqual(role, CFSTR("AXWebArea"));
        if (role) CFRelease(role);
        if (isPageArea) {
            [pageAreas addObject:CFBridgingRelease(CFRetain(element))];
            return YES;
        }
    }

    CFTypeRef childrenValue = CopyAttribute(element, kAXChildrenAttribute);
    if (gFailureStage && strcmp(gFailureStage, "accessibility_timeout") == 0) return NO;
    if (!childrenValue) return YES;
    if (CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
        CFRelease(childrenValue);
        return YES;
    }

    CFArrayRef children = (CFArrayRef)childrenValue;
    CFIndex childCount = CFArrayGetCount(children);
    if (childCount > 512) {
        CFRelease(childrenValue);
        gFailureStage = "side_peek_page_search_limit";
        return NO;
    }
    for (CFIndex i = 0; i < childCount; i++) {
        CFTypeRef childValue = CFArrayGetValueAtIndex(children, i);
        if (!childValue || CFGetTypeID(childValue) != AXUIElementGetTypeID()) continue;
        if (!WalkForSidePeekPageAreas(sidePeekScope, (AXUIElementRef)childValue,
                                      depth + 1, visited, pageAreas)) {
            CFRelease(childrenValue);
            return NO;
        }
    }
    CFRelease(childrenValue);
    return YES;
}

static int WriteSnapshot(NSDictionary *snapshot) {
    NSError *serializationError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:snapshot
                                                   options:0
                                                     error:&serializationError];
    if (!json || serializationError) return Fail("snapshot_serialization_failed");
    if (fwrite(json.bytes, 1, json.length, stdout) != json.length
            || fputc('\n', stdout) == EOF) {
        return Fail("snapshot_write_failed");
    }
    return 0;
}

static int EmitSidePeekPageSnapshot(AXUIElementRef sidePeekScope,
                                    AXUIElementRef pageArea) {
    CFStringRef titleValue = CopyStringAttribute(pageArea, kAXTitleAttribute);
    CFStringRef linkLabel = NULL;
    CFStringRef urlValue = NULL;
    int linkResult = CopyFullPageLinkFromAncestors(pageArea, &linkLabel, &urlValue);
    if (linkResult < 0) {
        if (titleValue) CFRelease(titleValue);
        return Fail(gFailureStage);
    }
    if (!titleValue || !urlValue || !linkLabel
            || CFStringGetLength(titleValue) == 0 || CFStringGetLength(urlValue) == 0) {
        if (titleValue) CFRelease(titleValue);
        if (linkLabel) CFRelease(linkLabel);
        if (urlValue) CFRelease(urlValue);
        gFailureStage = linkResult == 0 ? "page_link_missing" : "page_pair_missing";
        return Fail(gFailureStage);
    }

    CFStringRef scopeRole = CopyStringAttribute(sidePeekScope, kAXRoleAttribute);
    NSString *scopeRoleString = scopeRole
        ? (__bridge NSString *)scopeRole : @"AXGroup";
    NSDictionary *snapshot = @{
        @"accessibility_tree": @{
            @"focused_element": @"focused",
            @"nodes": @[
                @{@"id": @"window", @"parent": NSNull.null, @"role": @"AXWindow"},
                @{@"id": @"side-peek-scope", @"parent": @"window",
                  @"role": scopeRoleString, @"title": @"Side Peek"},
                @{@"id": @"side-page", @"parent": @"side-peek-scope",
                  @"role": @"AXWebArea", @"title": (__bridge NSString *)titleValue},
                @{@"id": @"focused", @"parent": @"window", @"role": @"AXGroup"},
                @{@"id": @"side-page-link", @"parent": @"side-page",
                  @"role": @"AXLink", @"description": (__bridge NSString *)linkLabel,
                  @"url": (__bridge NSString *)urlValue}
            ]
        }
    };
    int result = WriteSnapshot(snapshot);
    if (scopeRole) CFRelease(scopeRole);
    CFRelease(titleValue);
    CFRelease(linkLabel);
    CFRelease(urlValue);
    return result;
}

static int EmitFocusedPageSnapshot(void) {
    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (![frontmost.bundleIdentifier isEqualToString:@"notion.id"]) {
        return Fail("notion_not_frontmost");
    }

    AXUIElementRef application = AXUIElementCreateApplication((pid_t)frontmost.processIdentifier);
    if (!application) return Fail("notion_process_unavailable");
    AXUIElementSetMessagingTimeout(application, 0.5);

    CFTypeRef focusedValue = CopyAttribute(application, kAXFocusedUIElementAttribute);
    if (!focusedValue || CFGetTypeID(focusedValue) != AXUIElementGetTypeID()) {
        if (focusedValue) CFRelease(focusedValue);
        CFRelease(application);
        return Fail(gFailureStage);
    }

    AXUIElementRef current = (AXUIElementRef)focusedValue;
    AXUIElementRef webArea = NULL;
    NSUInteger parentSteps = 0;
    while (current && parentSteps < 64) {
        CFTypeRef roleValue = CopyAttribute(current, kAXRoleAttribute);
        if (roleValue && CFGetTypeID(roleValue) == CFStringGetTypeID()
                && CFEqual(roleValue, CFSTR("AXWebArea"))) {
            webArea = (AXUIElementRef)CFRetain(current);
            CFRelease(roleValue);
            break;
        }
        if (roleValue) CFRelease(roleValue);

        if (parentSteps >= 64) break;
        CFTypeRef parentValue = CopyAttribute(current, kAXParentAttribute);
        if (!parentValue || CFGetTypeID(parentValue) != AXUIElementGetTypeID()) {
            if (parentValue) CFRelease(parentValue);
            break;
        }
        AXUIElementRef parent = (AXUIElementRef)parentValue;
        if (CFEqual(current, parent)) {
            CFRelease(parent);
            break;
        }
        CFRelease(current);
        current = parent;
        parentSteps++;
    }

    if (current) CFRelease(current);
    if (!webArea && parentSteps >= 64) {
        CFRelease(application);
        return Fail("page_area_depth_limit");
    }
    if (!webArea) {
        CFRelease(application);
        return Fail(gFailureStage);
    }

    AXUIElementRef window = CopyAncestorWithRole(webArea, CFSTR("AXWindow"));
    if (!window) {
        CFTypeRef focusedWindowValue = CopyAttribute(application, kAXFocusedWindowAttribute);
        if (focusedWindowValue && CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID()) {
            window = (AXUIElementRef)focusedWindowValue;
        } else if (focusedWindowValue) {
            CFRelease(focusedWindowValue);
        }
    }
    if (!window) {
        CFRelease(webArea);
        CFRelease(application);
        return Fail("notion_window_unavailable");
    }

    NSMutableArray *sidePeekScopes = [NSMutableArray array];
    NSUInteger scopeNodesVisited = 0;
    if (!WalkForSidePeekScopes(window, 0, &scopeNodesVisited, sidePeekScopes)) {
        CFRelease(window);
        CFRelease(webArea);
        CFRelease(application);
        return Fail(gFailureStage);
    }
    if (sidePeekScopes.count > 1) {
        CFRelease(window);
        CFRelease(webArea);
        CFRelease(application);
        return Fail("side_peek_scope_ambiguous");
    }
    if (sidePeekScopes.count == 1) {
        AXUIElementRef sidePeekScope = (__bridge AXUIElementRef)sidePeekScopes[0];
        NSMutableArray *pageAreas = [NSMutableArray array];
        NSUInteger pageNodesVisited = 0;
        if (!WalkForSidePeekPageAreas(sidePeekScope, sidePeekScope, 0,
                                      &pageNodesVisited, pageAreas)) {
            CFRelease(window);
            CFRelease(webArea);
            CFRelease(application);
            return Fail(gFailureStage);
        }
        if (pageAreas.count != 1) {
            CFRelease(window);
            CFRelease(webArea);
            CFRelease(application);
            return Fail(pageAreas.count == 0
                ? "side_peek_page_missing" : "side_peek_page_ambiguous");
        }
        AXUIElementRef sidePageArea = (__bridge AXUIElementRef)pageAreas[0];
        int result = EmitSidePeekPageSnapshot(sidePeekScope, sidePageArea);
        CFRelease(window);
        CFRelease(webArea);
        CFRelease(application);
        return result;
    }
    CFRelease(window);

    CFStringRef titleValue = CopyStringAttribute(webArea, kAXTitleAttribute);
    CFStringRef urlValue = CopyURLAttribute(webArea);
    if (urlValue && CFStringGetLength(urlValue) == 0) {
        CFRelease(urlValue);
        urlValue = NULL;
    }
    CFStringRef linkLabel = NULL;
    if (!urlValue) {
        int linkResult = CopyFullPageLinkFromAncestors(webArea, &linkLabel, &urlValue);
        if (linkResult < 0) {
            if (titleValue) CFRelease(titleValue);
            CFRelease(webArea);
            CFRelease(application);
            return Fail(gFailureStage);
        }
        if (linkLabel) CFRelease(linkLabel);
    }
    CFRelease(webArea);
    CFRelease(application);
    if (!titleValue || !urlValue) {
        if (titleValue) CFRelease(titleValue);
        if (urlValue) CFRelease(urlValue);
        return Fail("page_pair_missing");
    }

    NSString *title = (__bridge NSString *)titleValue;
    NSString *url = (__bridge NSString *)urlValue;
    BOOL hasTitle = [[title stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] length] > 0;
    if (!hasTitle || url.length == 0) {
        CFRelease(titleValue);
        CFRelease(urlValue);
        return Fail("page_pair_missing");
    }

    NSDictionary *snapshot = @{
        @"accessibility_tree": @{
            @"focused_element": @"focused",
            @"nodes": @[
                @{@"id": @"pane", @"parent": NSNull.null,
                  @"role": @"AXWebArea", @"title": title},
                @{@"id": @"focused", @"parent": @"pane", @"role": @"AXGroup"},
                @{@"id": @"page-link", @"parent": @"pane", @"role": @"AXLink",
                  @"description": @"Open in full page", @"url": url}
            ]
        }
    };
    CFRelease(titleValue);
    CFRelease(urlValue);
    return WriteSnapshot(snapshot);
}

static int WritePasteboardPayload(void) {
    NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSError *parseError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:input options:0 error:&parseError];
    if (![object isKindOfClass:[NSDictionary class]]) return Fail("invalid_payload");

    NSDictionary *payload = (NSDictionary *)object;
    id titleValue = payload[@"title"];
    id urlValue = payload[@"url"];
    id plainValue = payload[@"plain"];
    id htmlValue = payload[@"html"];
    if (![titleValue isKindOfClass:[NSString class]]
            || ![urlValue isKindOfClass:[NSString class]]
            || ![plainValue isKindOfClass:[NSString class]]
            || ![htmlValue isKindOfClass:[NSString class]]
            || [(NSString *)titleValue length] == 0
            || [(NSString *)urlValue length] == 0
            || [(NSString *)plainValue length] == 0
            || [(NSString *)htmlValue length] == 0) {
        return Fail("invalid_payload");
    }

    NSData *htmlData = [(NSString *)htmlValue dataUsingEncoding:NSUTF8StringEncoding];
    if (!htmlData) return Fail("pasteboard_payload_encoding_failed");

    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    if (![item setString:(NSString *)plainValue forType:NSPasteboardTypeString]
            || ![item setData:htmlData forType:NSPasteboardTypeHTML]) {
        return Fail("pasteboard_payload_encoding_failed");
    }

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    if (![pasteboard writeObjects:@[item]]) return Fail("pasteboard_write_failed");
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--write-pasteboard") == 0) {
            return WritePasteboardPayload();
        }
        if (argc != 1) return Fail("invalid_arguments");
        gDeadline = CFAbsoluteTimeGetCurrent() + 5.0;
        return EmitFocusedPageSnapshot();
    }
}
