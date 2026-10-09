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

static CFTypeRef CopyDirectAttribute(AXUIElementRef element, CFStringRef attribute) {
    if (CFAbsoluteTimeGetCurrent() >= gDeadline) {
        gFailureStage = "accessibility_timeout";
        return NULL;
    }
    AXUIElementSetMessagingTimeout(element, 0.5);
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess) return NULL;
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

static CFStringRef CopyDirectStringAttribute(AXUIElementRef element, CFStringRef attribute) {
    if (CFAbsoluteTimeGetCurrent() >= gDeadline) {
        gFailureStage = "accessibility_timeout";
        return NULL;
    }
    AXUIElementSetMessagingTimeout(element, 0.5);
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess
            || !value || CFGetTypeID(value) != CFStringGetTypeID()) {
        if (value) CFRelease(value);
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

static CFStringRef CopyDirectURLAttribute(AXUIElementRef element) {
    const CFStringRef attributes[] = {kAXURLAttribute, kAXValueAttribute};
    for (NSUInteger i = 0; i < sizeof(attributes) / sizeof(attributes[0]); i++) {
        CFTypeRef value = CopyDirectAttribute(element, attributes[i]);
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

static BOOL IsLeafAccessibilityRole(CFStringRef role) {
    if (!role) return NO;
    const CFStringRef leafRoles[] = {
        CFSTR("AXButton"), CFSTR("AXCheckBox"), CFSTR("AXImage"),
        CFSTR("AXLink"), CFSTR("AXMenuItem"), CFSTR("AXMenuBarItem"),
        CFSTR("AXRadioButton"), CFSTR("AXStaticText"), CFSTR("AXTextArea"),
        CFSTR("AXTextField")
    };
    for (NSUInteger i = 0; i < sizeof(leafRoles) / sizeof(leafRoles[0]); i++) {
        if (CFEqual(role, leafRoles[i])) return YES;
    }
    return NO;
}

static BOOL IsPageTitleTextArea(AXUIElementRef element, CFStringRef role) {
    if (!role || !CFEqual(role, CFSTR("AXTextArea"))) return NO;

    CFStringRef roleDescription = CopyDirectStringAttribute(element, kAXRoleDescriptionAttribute);
    if (!roleDescription) return NO;
    NSString *normalized = [[(__bridge NSString *)roleDescription
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        lowercaseString];
    BOOL isPageTitle = [normalized containsString:@"title"]
        || [normalized containsString:@"タイトル"];
    CFRelease(roleDescription);
    if (!isPageTitle) return NO;

    CFStringRef value = CopyDirectStringAttribute(element, kAXValueAttribute);
    BOOL hasValue = value && CFStringGetLength(value) > 0;
    if (value) CFRelease(value);
    return hasValue;
}

static CFStringRef CopySidePeekPageTitle(AXUIElementRef pageElement) {
    CFStringRef role = CopyDirectStringAttribute(pageElement, kAXRoleAttribute);
    if (role && CFEqual(role, CFSTR("AXWebArea"))) {
        CFRelease(role);
        return CopyStringAttribute(pageElement, kAXTitleAttribute);
    }
    BOOL isTitleTextArea = IsPageTitleTextArea(pageElement, role);
    if (role) CFRelease(role);
    return isTitleTextArea
        ? CopyDirectStringAttribute(pageElement, kAXValueAttribute) : NULL;
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


static BOOL CopyFullPageLinkDirect(AXUIElementRef element,
                             CFStringRef *labelOut,
                             CFStringRef *urlOut) {
    CFStringRef role = CopyDirectStringAttribute(element, kAXRoleAttribute);
    BOOL isLink = role && CFEqual(role, CFSTR("AXLink"));
    if (role) CFRelease(role);
    if (!isLink) return NO;

    const CFStringRef labelAttributes[] = {
        kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute
    };
    CFStringRef label = NULL;
    for (NSUInteger i = 0; i < sizeof(labelAttributes) / sizeof(labelAttributes[0]); i++) {
        CFTypeRef value = CopyDirectAttribute(element, labelAttributes[i]);
        BOOL matches = IsFullPageLabel(value);
        if (matches && CFGetTypeID(value) == CFStringGetTypeID()) {
            label = (CFStringRef)value;
            break;
        }
        if (value) CFRelease(value);
    }
    if (!label) return NO;

    CFStringRef url = CopyDirectURLAttribute(element);
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

static int CopyFullPageLinkWithinScope(AXUIElementRef sidePeekScope,
                                       CFStringRef *labelOut,
                                       CFStringRef *urlOut) {
    NSMutableArray *pending = [NSMutableArray arrayWithObject:@{
        @"element": CFBridgingRelease(CFRetain(sidePeekScope)), @"depth": @0
    }];
    NSUInteger next = 0;
    NSUInteger scheduled = 1;
    NSUInteger visited = 0;
    CFStringRef matchedLabel = NULL;
    CFStringRef matchedURL = NULL;
    NSUInteger totalMatches = 0;

    while (next < pending.count) {
        if (CFAbsoluteTimeGetCurrent() >= gDeadline) {
            if (matchedLabel) CFRelease(matchedLabel);
            if (matchedURL) CFRelease(matchedURL);
            gFailureStage = "accessibility_timeout";
            return -1;
        }
        NSDictionary *entry = pending[next++];
        AXUIElementRef current = (__bridge AXUIElementRef)entry[@"element"];
        NSUInteger depth = [entry[@"depth"] unsignedIntegerValue];
        if (depth > 32 || ++visited > 2048) {
            if (matchedLabel) CFRelease(matchedLabel);
            if (matchedURL) CFRelease(matchedURL);
            gFailureStage = "page_link_search_limit";
            return -1;
        }

        if (!CFEqual(current, sidePeekScope)) {
            CFStringRef label = NULL;
            CFStringRef url = NULL;
            if (CopyFullPageLinkDirect(current, &label, &url)) {
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

        CFStringRef role = CopyDirectStringAttribute(current, kAXRoleAttribute);
        BOOL isLeaf = IsLeafAccessibilityRole(role);
        if (role) CFRelease(role);
        if (isLeaf) continue;

        CFTypeRef childrenValue = CopyDirectAttribute(current, kAXChildrenAttribute);
        if (!childrenValue) continue;
        if (CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
            CFRelease(childrenValue);
            continue;
        }
        CFArrayRef children = (CFArrayRef)childrenValue;
        CFIndex childCount = CFArrayGetCount(children);
        if (childCount > 512) {
            CFRelease(childrenValue);
            if (matchedLabel) CFRelease(matchedLabel);
            if (matchedURL) CFRelease(matchedURL);
            gFailureStage = "page_link_search_limit";
            return -1;
        }
        for (CFIndex i = 0; i < childCount; i++) {
            CFTypeRef childValue = CFArrayGetValueAtIndex(children, i);
            if (!childValue || CFGetTypeID(childValue) != AXUIElementGetTypeID()) continue;
            if (scheduled >= 2048) {
                CFRelease(childrenValue);
                if (matchedLabel) CFRelease(matchedLabel);
                if (matchedURL) CFRelease(matchedURL);
                gFailureStage = "page_link_search_limit";
                return -1;
            }
            [pending addObject:@{
                @"element": CFBridgingRelease(CFRetain((AXUIElementRef)childValue)),
                @"depth": @(depth + 1)
            }];
            scheduled++;
        }
        CFRelease(childrenValue);
    }

    if (totalMatches > 1) {
        if (matchedLabel) CFRelease(matchedLabel);
        if (matchedURL) CFRelease(matchedURL);
        gFailureStage = "page_link_ambiguous";
        return -1;
    }
    if (totalMatches == 1) {
        *labelOut = matchedLabel;
        *urlOut = matchedURL;
        return 1;
    }
    return 0;
}

static BOOL WalkForSidePeekScopes(AXUIElementRef element,
                                  NSUInteger depth,
                                  NSUInteger *visited,
                                  NSMutableArray *matches) {
    NSMutableArray *pending = [NSMutableArray arrayWithObject:@{
        @"element": CFBridgingRelease(CFRetain(element)), @"depth": @(depth)
    }];
    NSUInteger next = 0;
    NSUInteger scheduled = 1;
    while (next < pending.count) {
        if (CFAbsoluteTimeGetCurrent() >= gDeadline) {
            gFailureStage = "accessibility_timeout";
            return NO;
        }
        NSDictionary *entry = pending[next++];
        AXUIElementRef current = (__bridge AXUIElementRef)entry[@"element"];
        NSUInteger currentDepth = [entry[@"depth"] unsignedIntegerValue];
        if (currentDepth > 32 || ++(*visited) > 2048) {
            gFailureStage = "side_peek_scope_search_limit";
            return NO;
        }

        CFStringRef role = CopyStringAttribute(current, kAXRoleAttribute);
        if (gFailureStage && strcmp(gFailureStage, "accessibility_timeout") == 0) {
            if (role) CFRelease(role);
            return NO;
        }
        BOOL isLeaf = IsLeafAccessibilityRole(role);
        if (!isLeaf && IsSidePeekScope(current)) {
            [matches addObject:CFBridgingRelease(CFRetain(current))];
            if (role) CFRelease(role);
            continue;
        }
        if (role) CFRelease(role);
        if (isLeaf) continue;

        CFTypeRef childrenValue = CopyAttribute(current, kAXVisibleChildrenAttribute);
        if (gFailureStage && strcmp(gFailureStage, "accessibility_timeout") == 0) return NO;
        if (!childrenValue) continue;
        if (CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
            CFRelease(childrenValue);
            continue;
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
            if (scheduled >= 2048) {
                CFRelease(childrenValue);
                gFailureStage = "side_peek_scope_search_limit";
                return NO;
            }
            [pending addObject:@{
                @"element": CFBridgingRelease(CFRetain((AXUIElementRef)childValue)),
                @"depth": @(currentDepth + 1)
            }];
            scheduled++;
        }
        CFRelease(childrenValue);
    }
    return YES;
}

static BOOL WalkForVisiblePageAreas(AXUIElementRef element,
                                   NSUInteger depth,
                                   NSUInteger *visited,
                                   NSMutableArray *pageAreas) {
    NSMutableArray *pending = [NSMutableArray arrayWithObject:@{
        @"element": CFBridgingRelease(CFRetain(element)), @"depth": @(depth)
    }];
    NSUInteger next = 0;
    NSUInteger scheduled = 1;
    while (next < pending.count) {
        if (CFAbsoluteTimeGetCurrent() >= gDeadline) {
            gFailureStage = "accessibility_timeout";
            return NO;
        }
        NSDictionary *entry = pending[next++];
        AXUIElementRef current = (__bridge AXUIElementRef)entry[@"element"];
        NSUInteger currentDepth = [entry[@"depth"] unsignedIntegerValue];
        if (currentDepth > 32 || ++(*visited) > 2048) {
            gFailureStage = "page_area_search_limit";
            return NO;
        }

        CFStringRef role = CopyStringAttribute(current, kAXRoleAttribute);
        if (gFailureStage && strcmp(gFailureStage, "accessibility_timeout") == 0) {
            if (role) CFRelease(role);
            return NO;
        }
        if (!CFEqual(current, element) && IsSidePeekScope(current)) {
            if (role) CFRelease(role);
            continue;
        }
        BOOL isPageArea = role && CFEqual(role, CFSTR("AXWebArea"));
        if (isPageArea) {
            [pageAreas addObject:CFBridgingRelease(CFRetain(current))];
            if (role) CFRelease(role);
            continue;
        }
        BOOL isLeaf = IsLeafAccessibilityRole(role);
        if (role) CFRelease(role);
        if (isLeaf) continue;

        CFTypeRef childrenValue = CopyAttribute(current, kAXVisibleChildrenAttribute);
        if (gFailureStage && strcmp(gFailureStage, "accessibility_timeout") == 0) return NO;
        if (!childrenValue) continue;
        if (CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
            CFRelease(childrenValue);
            continue;
        }

        CFArrayRef children = (CFArrayRef)childrenValue;
        CFIndex childCount = CFArrayGetCount(children);
        if (childCount > 512) {
            CFRelease(childrenValue);
            gFailureStage = "page_area_search_limit";
            return NO;
        }
        for (CFIndex i = 0; i < childCount; i++) {
            CFTypeRef childValue = CFArrayGetValueAtIndex(children, i);
            if (!childValue || CFGetTypeID(childValue) != AXUIElementGetTypeID()) continue;
            if (scheduled >= 2048) {
                CFRelease(childrenValue);
                gFailureStage = "page_area_search_limit";
                return NO;
            }
            [pending addObject:@{
                @"element": CFBridgingRelease(CFRetain((AXUIElementRef)childValue)),
                @"depth": @(currentDepth + 1)
            }];
            scheduled++;
        }
        CFRelease(childrenValue);
    }
    return YES;
}

static BOOL WalkForSidePeekPageAreas(AXUIElementRef sidePeekScope,
                                     AXUIElementRef element,
                                     NSUInteger depth,
                                     NSUInteger *visited,
                                     NSMutableArray *pageAreas) {
    NSMutableArray *pending = [NSMutableArray arrayWithObject:@{
        @"element": CFBridgingRelease(CFRetain(element)), @"depth": @(depth)
    }];
    NSUInteger next = 0;
    NSUInteger scheduled = 1;
    while (next < pending.count) {
        if (CFAbsoluteTimeGetCurrent() >= gDeadline) {
            gFailureStage = "accessibility_timeout";
            return NO;
        }
        NSDictionary *entry = pending[next++];
        AXUIElementRef current = (__bridge AXUIElementRef)entry[@"element"];
        NSUInteger currentDepth = [entry[@"depth"] unsignedIntegerValue];
        if (currentDepth > 32 || ++(*visited) > 2048) {
            gFailureStage = "side_peek_page_search_limit";
            return NO;
        }

        CFStringRef role = CopyStringAttribute(current, kAXRoleAttribute);
        if (gFailureStage && strcmp(gFailureStage, "accessibility_timeout") == 0) {
            if (role) CFRelease(role);
            return NO;
        }
        BOOL isPageArea = !CFEqual(current, sidePeekScope)
            && role && CFEqual(role, CFSTR("AXWebArea"));
        if (isPageArea) {
            [pageAreas addObject:CFBridgingRelease(CFRetain(current))];
            if (role) CFRelease(role);
            continue;
        }
        BOOL isLeaf = IsLeafAccessibilityRole(role);
        if (role) CFRelease(role);
        if (isLeaf) continue;

        CFTypeRef childrenValue = CopyAttribute(current, kAXChildrenAttribute);
        if (gFailureStage && strcmp(gFailureStage, "accessibility_timeout") == 0) return NO;
        if (!childrenValue) continue;
        if (CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
            CFRelease(childrenValue);
            continue;
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
            if (scheduled >= 2048) {
                CFRelease(childrenValue);
                gFailureStage = "side_peek_page_search_limit";
                return NO;
            }
            [pending addObject:@{
                @"element": CFBridgingRelease(CFRetain((AXUIElementRef)childValue)),
                @"depth": @(currentDepth + 1)
            }];
            scheduled++;
        }
        CFRelease(childrenValue);
    }
    return YES;
}

static BOOL WalkForSidePeekPageTitles(AXUIElementRef sidePeekScope,
                                      NSUInteger *visited,
                                      NSMutableArray *pageTitles) {
    NSMutableArray *pending = [NSMutableArray arrayWithObject:@{
        @"element": CFBridgingRelease(CFRetain(sidePeekScope)), @"depth": @0
    }];
    NSUInteger next = 0;
    NSUInteger scheduled = 1;
    while (next < pending.count) {
        if (CFAbsoluteTimeGetCurrent() >= gDeadline) {
            gFailureStage = "accessibility_timeout";
            return NO;
        }
        NSDictionary *entry = pending[next++];
        AXUIElementRef current = (__bridge AXUIElementRef)entry[@"element"];
        NSUInteger depth = [entry[@"depth"] unsignedIntegerValue];
        if (depth > 32 || ++(*visited) > 2048) {
            gFailureStage = "side_peek_page_search_limit";
            return NO;
        }

        CFStringRef role = CopyDirectStringAttribute(current, kAXRoleAttribute);
        if (gFailureStage && strcmp(gFailureStage, "accessibility_timeout") == 0) {
            if (role) CFRelease(role);
            return NO;
        }
        BOOL isTitle = !CFEqual(current, sidePeekScope)
            && IsPageTitleTextArea(current, role);
        if (isTitle) {
            [pageTitles addObject:CFBridgingRelease(CFRetain(current))];
            if (role) CFRelease(role);
            continue;
        }
        BOOL isTextAreaContainer = role && CFEqual(role, CFSTR("AXTextArea"));
        BOOL isLeaf = IsLeafAccessibilityRole(role) && !isTextAreaContainer;
        if (role) CFRelease(role);
        if (isLeaf) continue;

        CFTypeRef childrenValue = CopyAttribute(current, kAXChildrenAttribute);
        if (gFailureStage && strcmp(gFailureStage, "accessibility_timeout") == 0) return NO;
        if (!childrenValue) continue;
        if (CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
            CFRelease(childrenValue);
            continue;
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
            if (scheduled >= 2048) {
                CFRelease(childrenValue);
                gFailureStage = "side_peek_page_search_limit";
                return NO;
            }
            [pending addObject:@{
                @"element": CFBridgingRelease(CFRetain((AXUIElementRef)childValue)),
                @"depth": @(depth + 1)
            }];
            scheduled++;
        }
        CFRelease(childrenValue);
    }
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
    CFStringRef titleValue = CopySidePeekPageTitle(pageArea);
    CFStringRef linkLabel = NULL;
    CFStringRef urlValue = NULL;
    int linkResult = CopyFullPageLinkWithinScope(sidePeekScope, &linkLabel, &urlValue);
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

    CFTypeRef focusedWindowValue = CopyAttribute(application, kAXFocusedWindowAttribute);
    if (!focusedWindowValue || CFGetTypeID(focusedWindowValue) != AXUIElementGetTypeID()) {
        if (focusedWindowValue) CFRelease(focusedWindowValue);
        CFRelease(application);
        return Fail("notion_window_unavailable");
    }
    AXUIElementRef window = (AXUIElementRef)focusedWindowValue;

    NSMutableArray *sidePeekScopes = [NSMutableArray array];
    NSUInteger scopeNodesVisited = 0;
    if (!WalkForSidePeekScopes(window, 0, &scopeNodesVisited, sidePeekScopes)) {
        CFRelease(window);
        CFRelease(application);
        return Fail(gFailureStage);
    }
    if (sidePeekScopes.count > 1) {
        CFRelease(window);
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
            CFRelease(application);
            return Fail(gFailureStage);
        }
        if (pageAreas.count == 0) {
            pageNodesVisited = 0;
            if (!WalkForSidePeekPageTitles(sidePeekScope, &pageNodesVisited, pageAreas)) {
                CFRelease(window);
                CFRelease(application);
                return Fail(gFailureStage);
            }
        }
        if (pageAreas.count != 1) {
            CFRelease(window);
            CFRelease(application);
            return Fail(pageAreas.count == 0
                ? "side_peek_page_missing" : "side_peek_page_ambiguous");
        }
        AXUIElementRef sidePageArea = (__bridge AXUIElementRef)pageAreas[0];
        int result = EmitSidePeekPageSnapshot(sidePeekScope, sidePageArea);
        CFRelease(window);
        CFRelease(application);
        return result;
    }

    NSMutableArray *visiblePageAreas = [NSMutableArray array];
    NSUInteger pageNodesVisited = 0;
    if (!WalkForVisiblePageAreas(window, 0, &pageNodesVisited, visiblePageAreas)) {
        CFRelease(window);
        CFRelease(application);
        return Fail(gFailureStage);
    }
    CFRelease(window);
    if (visiblePageAreas.count != 1) {
        CFRelease(application);
        return Fail(visiblePageAreas.count == 0
            ? "page_area_missing" : "page_area_ambiguous");
    }
    AXUIElementRef webArea = (__bridge AXUIElementRef)visiblePageAreas[0];

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
            CFRelease(application);
            return Fail(gFailureStage);
        }
        if (linkLabel) CFRelease(linkLabel);
    }
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
