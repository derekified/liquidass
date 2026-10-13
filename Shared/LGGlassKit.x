#import "LGGlassKit.h"
#import "LGCompat.h"
#import "LGLiveBackdropView.h"
#import "LGHostRegistry.h"
#import <objc/runtime.h>

#pragma mark - class / ancestry helpers

BOOL hasAncestorOfClassName(UIView *v, NSString *clsName) {
    Class cls = LGClassNamed(clsName);
    if (!cls) return NO;
    for (UIView *cur = v; cur; cur = cur.superview)
        if ([cur isKindOfClass:cls]) return YES;
    return NO;
}

BOOL ancestorNameContains(UIView *v, NSString *sub) {
    for (UIView *cur = v; cur; cur = cur.superview)
        if ([NSStringFromClass(cur.class) containsString:sub]) return YES;
    return NO;
}

BOOL isExactClass(UIView *v, NSString *name) {
    return LGObjectIsExactClass(v, name);
}

#pragma mark - per-host enable prefs

BOOL LGProcessMatchesExclusionList(id list) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier.lowercaseString ?: @"";
    if ([list isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)list)
            if ([value isKindOfClass:NSString.class] &&
                [bundleID isEqualToString:[value lowercaseString]]) return YES;
        return NO;
    }
    if (![list isKindOfClass:NSString.class] || ![list length]) return NO;
    NSString *executable =
        NSBundle.mainBundle.executablePath.lastPathComponent.lowercaseString ?: @"";
    NSString *processName = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
    NSCharacterSet *separators =
        [NSCharacterSet characterSetWithCharactersInString:@"\n,;"];
    for (NSString *rawEntry in [(NSString *)list componentsSeparatedByCharactersInSet:separators]) {
        NSString *entry = [rawEntry stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
        if (!entry.length || [entry hasPrefix:@"#"]) continue;
        if ([entry isEqualToString:bundleID] ||
            [entry isEqualToString:executable] ||
            [entry isEqualToString:processName]) return YES;
    }
    return NO;
}

BOOL lgHostEnabled(NSString *prefix) {
    if (!prefix.length) return YES;
    id global = LGGlassPreferenceValue(@"Global.Enabled");
    if (![prefix isEqualToString:@"Global"] && [global isKindOfClass:[NSNumber class]] && ![global boolValue])
        return NO;
    id v = LGGlassPreferenceValue([prefix stringByAppendingString:@".Enabled"]);

    if (!v) {
        static NSDictionary<NSString *, NSString *> *legacyPrefixes;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            legacyPrefixes = @{
                @"OpenFolder":   @"FolderOpen",
                @"AppLibSearch": @"AppLibrary.Search",
                @"Passcode":     @"Lockscreen.Passcode",
                @"Clock":        @"Lockscreen.Clock",
                @"QuickActions": @"LockscreenQuickActions",
            };
        });
        NSString *legacy = legacyPrefixes[prefix];
        if (legacy) v = LGGlassPreferenceValue([legacy stringByAppendingString:@".Enabled"]);
    }
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];

    if ([prefix isEqualToString:@"AppIcons"]) return NO;
    return YES;
}

#pragma mark - uniform injection registry

@interface LGGlassRec : NSObject
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic, weak) UIView *glass;
@property (nonatomic, weak) UIView *material;
@end
@implementation LGGlassRec @end

void *kGlassKey = &kGlassKey;

static NSMapTable<UIView *, LGGlassRec *> *sGlassRecs;
static NSMapTable<UIView *, NSString *> *sSuppressed;
static NSMutableArray<void (^)(void)> *sReloadHandlers;

@interface LGMaterialHostRoute : NSObject
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic) NSInteger priority;
@property (nonatomic, copy) LGMaterialHostMatcher matcher;
@property (nonatomic) UIEdgeInsets outset;
@property (nonatomic, copy) LGMaterialHostCornerRadiusProvider cornerRadiusProvider;
@property (nonatomic, copy) NSString *groupName;
@property (nonatomic, copy) LGMaterialHostPostInstall postInstall;
@end
@implementation LGMaterialHostRoute @end
static NSMutableArray<LGMaterialHostRoute *> *sMaterialHostRoutes;

void lgObservePreferenceReload(void (^handler)(void)) {
    if (!handler) return;
    if (!sReloadHandlers) sReloadHandlers = [NSMutableArray array];
    [sReloadHandlers addObject:[handler copy]];
}

void lgTrackGlass(UIView *glass, NSString *prefix, UIView *material) {
    if (!glass || !prefix.length) return;
    if (!sGlassRecs) sGlassRecs = [NSMapTable weakToStrongObjectsMapTable];
    LGGlassRec *existing = [sGlassRecs objectForKey:glass];
    if (existing) {
        existing.prefix = prefix;
        existing.material = material;
        return;
    }
    LGGlassRec *rec = [LGGlassRec new];
    rec.prefix = prefix; rec.glass = glass; rec.material = material;
    [sGlassRecs setObject:rec forKey:glass];
}

static const void *kLGAlphaForwardKey = &kLGAlphaForwardKey;

BOOL LGIsIconHostView(UIView *view) {
    return [NSStringFromClass(view.class) containsString:@"Icon"];
}

BOOL LGIsStockChromeView(UIView *view) {
    if (!view || [view isKindOfClass:LGLiveBackdropView.class] || LGIsIconHostView(view)) return NO;
    NSString *name = NSStringFromClass(view.class);
    if ([name hasPrefix:@"LG"]) return NO;
    return [name isEqualToString:@"SBWallpaperEffectView"] ||
           [name isEqualToString:@"MTMaterialView"] ||
           [name isEqualToString:@"SBFolderIconBackgroundView"] ||
           [name isEqualToString:@"SBFolderBackgroundView"] ||
           [name containsString:@"Wallpaper"] ||
           [name containsString:@"Backdrop"] ||
           [name containsString:@"Material"] ||
           [name containsString:@"Blur"] ||
           [name containsString:@"Background"];
}

static const void *kLGStockDetachedKey = &kLGStockDetachedKey;
static const void *kLGDetachedParentKey = &kLGDetachedParentKey;
static const void *kLGDetachedHoldKey = &kLGDetachedHoldKey;

void lgSuppressStock(UIView *v, NSString *prefix, BOOL setHidden) {
    if (!v || !prefix.length) return;
    if (setHidden) {
        // The setAlpha: hook forwards onto the glass unless this flag is set.
        objc_setAssociatedObject(v, kLGAlphaForwardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        v.hidden = YES;
        v.alpha = 0.0;
        v.opaque = NO;
        v.backgroundColor = UIColor.clearColor;
        v.layer.opacity = 0.0;
        v.layer.backgroundColor = UIColor.clearColor.CGColor;
        objc_setAssociatedObject(v, kLGAlphaForwardKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    if (!sSuppressed) sSuppressed = [NSMapTable weakToStrongObjectsMapTable];
    [sSuppressed setObject:prefix forKey:v];
}

BOOL LGStockViewIsDetached(UIView *view) {
    return view && objc_getAssociatedObject(view, kLGStockDetachedKey) != nil;
}

void lgDetachStock(UIView *view, NSString *prefix) {
    if (!view || !prefix.length) return;
    if ([NSStringFromClass(view.class) hasPrefix:@"LG"]) return;
    lgSuppressStock(view, prefix, YES);
    UIView *parent = view.superview;
    if (!parent) {
        objc_setAssociatedObject(view, kLGStockDetachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSMutableArray *held = objc_getAssociatedObject(parent, kLGDetachedHoldKey);
    if (!held) {
        held = [NSMutableArray array];
        objc_setAssociatedObject(parent, kLGDetachedHoldKey, held, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (![held containsObject:view]) [held addObject:view];
    objc_setAssociatedObject(view, kLGDetachedParentKey, parent, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, kLGStockDetachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [view removeFromSuperview];
}

void lgRestoreStock(UIView *view) {
    if (!view) return;
    UIView *parent = objc_getAssociatedObject(view, kLGDetachedParentKey);
    NSMutableArray *held = parent ? objc_getAssociatedObject(parent, kLGDetachedHoldKey) : nil;
    [held removeObject:view];
    objc_setAssociatedObject(view, kLGStockDetachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, kLGDetachedParentKey, nil, OBJC_ASSOCIATION_ASSIGN);
    view.hidden = NO;
    view.alpha = 1.0;
    view.layer.opacity = 1.0;
    if (parent && view.superview != parent) [parent insertSubview:view atIndex:0];
    [sSuppressed removeObjectForKey:view];
}

BOOL LGStockAlphaShouldSuppress(UIView *material, CGFloat alpha) {
    if (!LGMaterialHasGlass(material, kGlassKey)) return NO;
    if (objc_getAssociatedObject(material, kLGAlphaForwardKey)) return NO;
    UIView *glass = objc_getAssociatedObject(material, kGlassKey);
    glass.hidden = alpha <= 0.001;
    glass.alpha = alpha;
    objc_setAssociatedObject(material, kLGAlphaForwardKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

void LGStockAlphaSuppressed(UIView *material) {
    material.hidden = YES;
    material.alpha = 0.0;
    material.layer.opacity = 0.0;
    objc_setAssociatedObject(material, kLGAlphaForwardKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

#pragma mark - registered material lifecycle

LGLiveBackdropView *LGCreateRegisteredGlass(CGRect frame,
                                             NSString *groupName,
                                             NSString *prefix) {
    if (!prefix.length) return nil;
    NSString *filterType = LGFilterTypeForHostPrefix(prefix);
    if (!filterType) {
        LGLog(@"lifecycle rejected unknown host prefix=%@", prefix);
        return nil;
    }
    return [[LGLiveBackdropView alloc]
        initWithFrame:frame
            groupName:groupName
           filterType:filterType];
}

LGLiveBackdropView *LGInstallRegisteredGlassInMaterial(UIView *material,
                                                        const void *associationKey,
                                                        NSString *prefix,
                                                        UIEdgeInsets outset,
                                                        CGFloat cornerRadius,
                                                        NSString *groupName) {
    if (!material || !associationKey || !prefix.length) return nil;
    const LGHostDefinition *host =
        LGHostDefinitionForPreferencePrefix(prefix.UTF8String);
    if (!host) {
        LGLog(@"lifecycle rejected unknown host prefix=%@", prefix);
        return nil;
    }
    if (!lgHostEnabled(prefix)) {
        LGRemoveGlassFromMaterial(material, associationKey);
        return nil;
    }

    NSString *filterType = [NSString stringWithUTF8String:host->filterType];
    LGInjectGlassIntoMaterialGroupType(material, associationKey, outset,
                                       cornerRadius, groupName, filterType);
    LGLiveBackdropView *glass = objc_getAssociatedObject(material, associationKey);
    if (glass) lgTrackGlass(glass, prefix, material);
    return glass;
}

void LGRegisterMaterialHost(NSString *prefix,
                            NSInteger priority,
                            LGMaterialHostMatcher matcher,
                            UIEdgeInsets outset,
                            LGMaterialHostCornerRadiusProvider cornerRadiusProvider,
                            NSString *groupName,
                            LGMaterialHostPostInstall postInstall) {
    if (!prefix.length || !matcher ||
        !LGHostDefinitionForPreferencePrefix(prefix.UTF8String)) {
        LGLog(@"router rejected invalid material host prefix=%@", prefix);
        return;
    }
    if (!sMaterialHostRoutes) sMaterialHostRoutes = [NSMutableArray array];
    for (LGMaterialHostRoute *route in sMaterialHostRoutes) {
        if ([route.prefix isEqualToString:prefix]) return;
    }
    LGMaterialHostRoute *route = [LGMaterialHostRoute new];
    route.prefix = prefix;
    route.priority = priority;
    route.matcher = [matcher copy];
    route.outset = outset;
    route.cornerRadiusProvider = [cornerRadiusProvider copy];
    route.groupName = groupName;
    route.postInstall = [postInstall copy];
    [sMaterialHostRoutes addObject:route];
    // priority makes one host own each material
    [sMaterialHostRoutes sortUsingComparator:^NSComparisonResult(LGMaterialHostRoute *a,
                                                                   LGMaterialHostRoute *b) {
        if (a.priority == b.priority) return [a.prefix compare:b.prefix];
        return a.priority > b.priority ? NSOrderedAscending : NSOrderedDescending;
    }];
}

static void lgRouteMaterialHost(UIView *material) {
    if (!material.window) {
        LGRemoveGlassFromMaterial(material, kGlassKey);
        return;
    }
    for (LGMaterialHostRoute *route in sMaterialHostRoutes) {
        if (!route.matcher(material)) continue;
        CGFloat radius = route.cornerRadiusProvider
            ? route.cornerRadiusProvider(material) : -1.0;
        LGLiveBackdropView *glass = LGInstallRegisteredGlassInMaterial(
            material, kGlassKey, route.prefix, route.outset, radius, route.groupName);
        if (glass && route.postInstall) route.postInstall(material, glass);
        if (glass && ([route.prefix isEqualToString:@"Dock"] ||
                      [route.prefix isEqualToString:@"FolderIcon"]))
            lgDetachStock(material, route.prefix);
        return;
    }
}

static void lgReconcileInjectionsForDisable(void) {
    // disabled hosts must restore stock views and remove live glass
    if (sGlassRecs.count) {
        for (UIView *glass in sGlassRecs.keyEnumerator.allObjects) {
            LGGlassRec *r = [sGlassRecs objectForKey:glass];
            if (!r) continue;
            if (!lgHostEnabled(r.prefix)) {
                if (r.material) LGRemoveGlassFromMaterial(r.material, kGlassKey);
                else            [glass removeFromSuperview];
                [sGlassRecs removeObjectForKey:glass];
            }
        }
    }
    for (UIView *v in sSuppressed.keyEnumerator.allObjects) {
        NSString *p = [sSuppressed objectForKey:v];
        if (p && !lgHostEnabled(p)) lgRestoreStock(v);
    }
}

static void lgEnablePrefsReloadCallback(CFNotificationCenterRef c, void *o, CFStringRef n,
                                        const void *obj, CFDictionaryRef info) {
    LGLog(@"prefs Reload received; invalidating SpringBoard host-enable cache");
    LGInvalidateGlassPreferenceCache();

    dispatch_async(dispatch_get_main_queue(), ^{
        lgReconcileInjectionsForDisable();
        LGLog(@"prefs Reload reconciled material hosts; extraHandlers=%lu",
              (unsigned long)sReloadHandlers.count);
        for (void (^handler)(void) in [sReloadHandlers copy]) handler();
    });
}

__attribute__((constructor)) static void lgGlassInitEnableObserver(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, lgEnablePrefsReloadCallback, CFSTR("dylv.liquidassprefs/Reload"),
        NULL, CFNotificationSuspensionBehaviorCoalesce);
}

#pragma mark - shared material lifecycle

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window && LGStockViewIsDetached((UIView *)self)) return;
    lgRouteMaterialHost((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    lgRouteMaterialHost((UIView *)self);
}

- (void)setHidden:(BOOL)hidden {
    if (LGMaterialHasGlass((UIView *)self, kGlassKey)) hidden = YES;
    %orig(hidden);
}

- (void)setAlpha:(CGFloat)alpha {
    UIView *material = (UIView *)self;
    if (LGStockAlphaShouldSuppress(material, alpha)) {
        %orig(0);
        LGStockAlphaSuppressed(material);
        return;
    }
    %orig(alpha);
}

- (void)setFrame:(CGRect)frame {
    %orig(frame);
    LGResyncGlassGeometry((UIView *)self, kGlassKey);
}

- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    LGResyncGlassGeometry((UIView *)self, kGlassKey);
}

- (void)setCenter:(CGPoint)center {
    %orig(center);
    LGResyncGlassGeometry((UIView *)self, kGlassKey);
}

%end

%group LGLegacyMaterialRouting

%hook SBWallpaperEffectView

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window && LGStockViewIsDetached((UIView *)self)) return;
    lgRouteMaterialHost((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    lgRouteMaterialHost((UIView *)self);
}

- (void)setHidden:(BOOL)hidden {
    if (LGMaterialHasGlass((UIView *)self, kGlassKey)) hidden = YES;
    %orig(hidden);
}

- (void)setAlpha:(CGFloat)alpha {
    UIView *material = (UIView *)self;
    if (LGStockAlphaShouldSuppress(material, alpha)) {
        %orig(0);
        LGStockAlphaSuppressed(material);
        return;
    }
    %orig(alpha);
}

- (void)setFrame:(CGRect)frame {
    %orig(frame);
    LGResyncGlassGeometry((UIView *)self, kGlassKey);
}

- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    LGResyncGlassGeometry((UIView *)self, kGlassKey);
}

%end

%end

%ctor {
    %init;
    Class wallpaperEffectView = NSClassFromString(@"SBWallpaperEffectView");
    if (wallpaperEffectView && NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 13)
        %init(LGLegacyMaterialRouting, SBWallpaperEffectView = wallpaperEffectView);
}
