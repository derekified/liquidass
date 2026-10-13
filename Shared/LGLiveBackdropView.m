#import "LGLiveBackdropView.h"
#import "LGHostRegistry.h"
#import "LGCoverSheetState.h"
#import "LGCompat.h"
#import "LGRendererState.h"
#import "LGKitGlassView.h"
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <time.h>
#import <math.h>
#import <unistd.h>
#import <stdatomic.h>

static const void *kLGOutsetKey = &kLGOutsetKey;
static const void *kLGRadiusKey = &kLGRadiusKey;
static const void *kLGSpecularEnabledOverrideKey = &kLGSpecularEnabledOverrideKey;

static NSDictionary<NSString *, id> *sLGGlassPreferences;

static NSString *LGGlassPreferencesPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = jbroot(@"/var/mobile/Library/Preferences/dylv.liquidassprefs.plist");
    });
    return path;
}

id LGGlassPreferenceValue(NSString *key) {
    if (!key.length) return nil;
    @synchronized([LGLiveBackdropView class]) {
        if (!sLGGlassPreferences) {
            sLGGlassPreferences =
                [NSDictionary dictionaryWithContentsOfFile:LGGlassPreferencesPath()] ?: @{};
        }
        return sLGGlassPreferences[key];
    }
}

void LGInvalidateGlassPreferenceCache(void) {
    @synchronized([LGLiveBackdropView class]) {
        sLGGlassPreferences = nil;
    }
}

NSString *LGFilterTypeForHostPrefix(NSString *prefix) {
    if (!prefix.length) return nil;
    const LGHostDefinition *host =
        LGHostDefinitionForPreferencePrefix(prefix.UTF8String);
    return host ? [NSString stringWithUTF8String:host->filterType] : nil;
}

static void sblog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sblog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *format = [NSString stringWithUTF8String:fmt ?: ""];
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    LGLog(@"[LGSB] %@", message);
}

static const NSInteger kLGDynamicRadiusSteps = 32;

static BOOL LGNeedsGaussianIdentityFallback(void) {
    return access("/var/mobile/Library/Accessibility/liquidass-gaussian-identity-state.bin",
                  F_OK) == 0;
}

static CFStringRef const kLGParametersReloadedNotification =
    CFSTR("dylv.liquidglass/ParametersReloaded");

static uint64_t sLGRendererState = LGRendererStateUnknown;
static BOOL sLGRendererStateLoaded;

static void LGRefreshRendererState(void) {
    uint64_t state = LGRendererStateRead();
    if (!sLGRendererStateLoaded || state != sLGRendererState)
        LGLog(@"[LGSB] backboardd renderer state=%llu", (unsigned long long)state);
    sLGRendererState = state;
    sLGRendererStateLoaded = YES;
}

static BOOL LGRendererCompositing(void) {
    if (!sLGRendererStateLoaded) LGRefreshRendererState();
    return sLGRendererState == LGRendererStateActive;
}

static BOOL LGRendererUnavailable(void) {
    if (!sLGRendererStateLoaded) LGRefreshRendererState();
    return sLGRendererState == LGRendererStateUnknown ||
           sLGRendererState == LGRendererStateUnavailable;
}

static BOOL LGHostUsesFallbackMaterial(enum LGHostIdentifier host) {
    switch (host) {
        case LGHostIdentifierClock:
        case LGHostIdentifierCoverSheet:
        case LGHostIdentifierCount:
            return NO;
        default:
            return YES;
    }
}

// iOS 12 QuartzCore never composites the backboardd glass pass, so the LiquidGlassKit
// engine renders in-process there; later systems use it only when backboardd gave up.
static BOOL LGKitEngineWanted(enum LGHostIdentifier host) {
    if (!LGHostUsesFallbackMaterial(host) || UIAccessibilityIsReduceTransparencyEnabled()) return NO;
    if (!LGSystemVersionAtLeast(13)) return YES;
    return LGRendererUnavailable();
}

static BOOL LGHostPreferenceNumber(NSString *prefix, NSString *suffix, CGFloat *value) {
    id number = LGGlassPreferenceValue([prefix stringByAppendingString:suffix]);
    if (![number isKindOfClass:NSNumber.class]) return NO;
    double raw = [number doubleValue];
    if (!isfinite(raw)) return NO;
    *value = raw;
    return YES;
}

static BOOL LGHostIsClearVariant(enum LGHostIdentifier host) {
    switch (host) {
        case LGHostIdentifierPrefsSlider:
        case LGHostIdentifierPrefsSwitch:
        case LGHostIdentifierPrefsSegment:
        case LGHostIdentifierTabBarSelection:
            return YES;
        default:
            return NO;
    }
}

static BOOL LGParseTintHex(id value, CGFloat rgba[4]) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *hex = [[(NSString *)value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return NO;
    unsigned int raw = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&raw]) return NO;
    if (hex.length == 6) raw = (raw << 8) | 0xffu;
    rgba[0] = ((raw >> 24) & 0xff) / 255.0;
    rgba[1] = ((raw >> 16) & 0xff) / 255.0;
    rgba[2] = ((raw >> 8) & 0xff) / 255.0;
    rgba[3] = (raw & 0xff) / 255.0;
    return YES;
}

@interface LGFallbackMaterialView : UIView
- (void)lgApplyBlurRadius:(CGFloat)radius saturation:(CGFloat)saturation tint:(UIColor *)tint;
@end

@implementation LGFallbackMaterialView {
    CALayer *_tintLayer;
    CGFloat _radius;
    CGFloat _saturation;
}

+ (Class)layerClass { return NSClassFromString(@"CABackdropLayer") ?: CALayer.class; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.clipsToBounds = YES;
    _radius = -1.0;
    _tintLayer = [CALayer layer];
    [self.layer addSublayer:_tintLayer];
    Class backdrop = NSClassFromString(@"CABackdropLayer");
    if (backdrop && [self.layer isKindOfClass:backdrop]) {
        LGLayerSetValueIfSupported(self.layer, @"layerUsesCoreImageFilters", @NO);
        LGLayerSetValueIfSupported(self.layer, @"windowServerAware", @YES);
        LGLayerSetValueIfSupported(self.layer, @"groupName", NSUUID.UUID.UUIDString);
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _tintLayer.frame = self.bounds;
    [CATransaction commit];
}

- (void)lgApplyBlurRadius:(CGFloat)radius saturation:(CGFloat)saturation tint:(UIColor *)tint {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _tintLayer.frame = self.bounds;
    _tintLayer.backgroundColor = tint.CGColor;
    [CATransaction commit];
    if (fabs(_radius - radius) < 0.01 && fabs(_saturation - saturation) < 0.01) return;
    _radius = radius;
    _saturation = saturation;
    Class backdrop = NSClassFromString(@"CABackdropLayer");
    Class filterClass = NSClassFromString(@"CAFilter");
    SEL filterWithName = NSSelectorFromString(@"filterWithName:");
    if (!backdrop || ![self.layer isKindOfClass:backdrop] ||
        ![filterClass respondsToSelector:filterWithName]) return;
    NSMutableArray *filters = [NSMutableArray arrayWithCapacity:2];
    @try {
        if (radius > 0.0) {
            id blur = ((id (*)(Class, SEL, NSString *))objc_msgSend)(filterClass, filterWithName, @"gaussianBlur");
            [blur setValue:@(radius) forKey:@"inputRadius"];
            [blur setValue:@YES forKey:@"inputNormalizeEdges"];
            if (blur) [filters addObject:blur];
        }
        if (fabs(saturation - 1.0) > 0.01) {
            id saturate = ((id (*)(Class, SEL, NSString *))objc_msgSend)(filterClass, filterWithName, @"colorSaturate");
            [saturate setValue:@(saturation) forKey:@"inputAmount"];
            if (saturate) [filters addObject:saturate];
        }
        self.layer.filters = filters.count ? filters : nil;
    } @catch (__unused NSException *exception) {}
}
@end
static NSHashTable<LGLiveBackdropView *> *sLGAllGlasses;
static BOOL sLGFilterRefreshSetup;
static BOOL LGSpecularEnabledForFilterType(NSString *type) {
    const LGHostDefinition *host = LGHostDefinitionForFilterType(type.UTF8String);
    if (host == &kLGHostRegistry[LGHostIdentifierCoverSheet]) return NO;
    if (host && host->specularOpacity <= 0.001f) return NO;
    NSString *prefix = host ? [NSString stringWithUTF8String:host->preferencePrefix] : nil;
    if (!prefix.length) return YES;
    id value = LGGlassPreferenceValue([prefix stringByAppendingString:@".SpecularEnabled"]);
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

static NSHashTable<LGLiveBackdropView *> *sLGMotionGlasses;
static CMMotionManager *sLGMotionManager;
static NSOperationQueue *sLGMotionQueue;
static BOOL sLGMotionSetup;
static BOOL sLGMotionRunning;
static CGFloat sLGSpecularAngle = -M_PI_4;
static CGFloat sLGTargetSpecularAngle = -M_PI_4;
static CGFloat sLGLastTargetSpecularAngle = -M_PI_4;
static CGFloat sLGLastAppliedSpecularAngle = -100.0;
static CADisplayLink *sLGMotionDisplayLink;
static BOOL sLGMotionEnabled;
static CGFloat sLGMotionSensitivity = 2.0;
static CGFloat sLGMotionLoggedSensitivity = -1.0;
static CFStringRef const kLGMotionPrefsReloadNotification = CFSTR("dylv.liquidassprefs/Reload");

static void LGApplyMotionHighlightAngle(void);
static void LGRefreshMotionHighlights(void);
static void LGEnsureFilterRefreshObserver(void);

@interface LGMotionDisplayLinkTarget : NSObject
- (void)tick:(CADisplayLink *)displayLink;
@end

static BOOL LGIsSpringBoardBundle(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static void LGReloadMotionHighlightPreferences(void) {
    id enabled = LGGlassPreferenceValue(@"Specular.Motion.Enabled");
    id sensitivity = LGGlassPreferenceValue(@"Specular.Motion.Sensitivity");
    BOOL previousEnabled = sLGMotionEnabled;
    CGFloat previousSensitivity = sLGMotionSensitivity;
    sLGMotionEnabled = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : NO;
    CGFloat value = [sensitivity respondsToSelector:@selector(doubleValue)] ? [sensitivity doubleValue] : 2.0;
    sLGMotionSensitivity = MAX(0.0, MIN(8.0, value));
    if (sLGMotionLoggedSensitivity < 0.0 || previousEnabled != sLGMotionEnabled ||
        fabs(previousSensitivity - sLGMotionSensitivity) > 0.01) {
        sLGMotionLoggedSensitivity = sLGMotionSensitivity;
        LGLog(@"motion highlights prefs enabled=%d sensitivity=%.2f", sLGMotionEnabled, sLGMotionSensitivity);
    }
}

static void LGMotionPreferencesDidChange(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGInvalidateGlassPreferenceCache();
        LGReloadMotionHighlightPreferences();
        LGRefreshMotionHighlights();
    });
}

static BOOL LGUsesDynamicRadiusType(NSString *filterType) {

    return filterType.length &&
           LGHostIdentifierForFilterType(filterType.UTF8String) != LGHostIdentifierClock;
}

static BOOL LGUsesPrefsControlCaptureScale(NSString *filterType) {
    switch (LGHostIdentifierForFilterType(filterType.UTF8String)) {
        case LGHostIdentifierPrefsSlider:
        case LGHostIdentifierPrefsSwitch:
        case LGHostIdentifierPrefsButton:
        case LGHostIdentifierPrefsSegment:
            return YES;
        default:
            return NO;
    }
}

static CGFloat LGNativeBlurRadiusForFilterType(NSString *filterType) {
    const LGHostDefinition *host = LGHostDefinitionForFilterType(filterType.UTF8String);
    if (!host) return 0.0;
    NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
    id value = LGGlassPreferenceValue([prefix stringByAppendingString:@".Blur"]);
    return [value respondsToSelector:@selector(doubleValue)]
        ? MAX(0.0, [value doubleValue]) : host->blur;
}

static const CGFloat kLGScaleMax    = 0.75;
static const CGFloat kLGScaleMin    = 0.25;

static const CGFloat kLGClockCaptureScale = 0.50;

static const CGFloat kLGPrefsControlScale = 1.50;
static const CGFloat kLGDefaultScaleBudget = 8000.0;
static CGFloat LGQualityValue(void) {
    id value = LGGlassPreferenceValue(@"Global.Quality");
    CGFloat quality = [value respondsToSelector:@selector(doubleValue)]
        ? (CGFloat)[value doubleValue] : 1.0;
    if (!isfinite(quality)) quality = 1.0;
    return fmin(1.0, fmax(0.1, quality));
}

static CGFloat LGScaleBudget(void) {
    return kLGDefaultScaleBudget * LGQualityValue();
}

static CGFloat LGScaleForSize(CGSize s) {
    // area budget keeps total capture cost predictable
    CGFloat area = s.width * s.height;
    if (area <= 1.0) return kLGScaleMax;
    CGFloat scale = sqrt(LGScaleBudget() / area);
    return fmin(kLGScaleMax, fmax(kLGScaleMin, scale));
}

@interface LGLiveBackdropView ()
- (void)updateSpecular;
- (void)applySpecularAngle:(CGFloat)angle;
- (void)reapplyFilterForParameterReload;
@end

static void LGParametersReloaded(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{

        // clear cached prefs before rebuilding every live filter
        LGInvalidateGlassPreferenceCache();
        LGRefreshRendererState();
        NSArray<LGLiveBackdropView *> *glasses = sLGAllGlasses.allObjects;
        LGLog(@"render parameters ready; refreshing %lu live filters",
              (unsigned long)glasses.count);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (LGLiveBackdropView *glass in glasses) {
            [glass reapplyFilterForParameterReload];
        }
        [CATransaction commit];
    });
}

static void LGEnsureFilterRefreshObserver(void) {
    if (!sLGAllGlasses) sLGAllGlasses = [NSHashTable weakObjectsHashTable];
    if (sLGFilterRefreshSetup) return;
    sLGFilterRefreshSetup = YES;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LGParametersReloaded,
                                    kLGParametersReloadedNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIAccessibilityReduceTransparencyStatusDidChangeNotification
                    object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
        for (LGLiveBackdropView *glass in sLGAllGlasses.allObjects) {
            [glass reapplyFilterForParameterReload];
        }
    }];
}

static void LGApplyMotionHighlightAngle(void) {
    if (sLGMotionGlasses.count == 0) return;
    if (sLGMotionDisplayLink && sLGMotionDisplayLink.paused &&
        fabs(sLGSpecularAngle - sLGLastAppliedSpecularAngle) < 0.001) return;
    sLGLastAppliedSpecularAngle = sLGSpecularAngle;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (LGLiveBackdropView *glass in sLGMotionGlasses.allObjects) {
        UIWindow *window = glass.window;
        if (!window || glass.hidden || glass.alpha <= 0.01 ||
            window.hidden || window.alpha <= 0.01) continue;
        CGRect bounds = glass.bounds;
        if (CGRectIsEmpty(bounds) ||
            !CGRectIntersectsRect(window.bounds, [glass convertRect:bounds toView:nil])) continue;
        [glass applySpecularAngle:sLGSpecularAngle];
    }
    [CATransaction commit];
}

@implementation LGMotionDisplayLinkTarget
- (void)tick:(CADisplayLink *)displayLink {
    CGFloat dt = displayLink.targetTimestamp > displayLink.timestamp
        ? displayLink.targetTimestamp - displayLink.timestamp : 1.0 / 60.0;
    CGFloat delta = atan2(sin(sLGTargetSpecularAngle - sLGSpecularAngle),
                          cos(sLGTargetSpecularAngle - sLGSpecularAngle));
    if (fabs(delta) < 0.001) {
        sLGSpecularAngle = sLGTargetSpecularAngle;
        LGApplyMotionHighlightAngle();
        displayLink.paused = YES;
        return;
    }
    CGFloat response = 1.0 - exp(-14.0 * dt);
    sLGSpecularAngle += delta * response;
    LGApplyMotionHighlightAngle();
}
@end

static void LGRefreshMotionHighlights(void) {
    if (!sLGMotionSetup || !LGIsSpringBoardBundle()) return;
    if (!sLGMotionEnabled) {
        [sLGMotionManager stopDeviceMotionUpdates];
        [sLGMotionDisplayLink invalidate];
        sLGMotionDisplayLink = nil;
        sLGMotionRunning = NO;
        sLGSpecularAngle = -M_PI_4;
        sLGTargetSpecularAngle = sLGSpecularAngle;
        sLGLastAppliedSpecularAngle = -100.0;
        LGApplyMotionHighlightAngle();
        return;
    }
    if (sLGMotionRunning) return;

    if (!sLGMotionQueue) {
        sLGMotionQueue = [[NSOperationQueue alloc] init];
        sLGMotionQueue.name = @"com.ngkhoi.liquidass.motion";
        sLGMotionQueue.maxConcurrentOperationCount = 1;
        sLGMotionQueue.qualityOfService = NSQualityOfServiceUtility;
    }

    CMAttitudeReferenceFrame frame = CMAttitudeReferenceFrameXArbitraryZVertical;

    sLGMotionManager.deviceMotionUpdateInterval = 1.0 / 30.0;
    static LGMotionDisplayLinkTarget *displayLinkTarget;
    if (!displayLinkTarget) displayLinkTarget = [LGMotionDisplayLinkTarget new];
    if (!sLGMotionDisplayLink) {
        sLGMotionDisplayLink = [CADisplayLink displayLinkWithTarget:displayLinkTarget
                                                           selector:@selector(tick:)];
        [sLGMotionDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                   forMode:NSRunLoopCommonModes];
    }
    sLGMotionRunning = YES;
    [sLGMotionManager startDeviceMotionUpdatesUsingReferenceFrame:frame
                                                            toQueue:sLGMotionQueue
                                                        withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (!motion || error || !sLGMotionEnabled) return;
        CMAttitude *attitude = motion.attitude;

        CGFloat baseMotion = attitude.roll * 1.2 + attitude.pitch * 1.2 + attitude.yaw;
        CGFloat target = baseMotion * (sLGMotionSensitivity * 1.2);
        CGFloat delta = atan2(sin(target - sLGLastTargetSpecularAngle),
                              cos(target - sLGLastTargetSpecularAngle));
        if (fabs(delta) <= 0.001) return;
        sLGLastTargetSpecularAngle = target;
        sLGTargetSpecularAngle = target;
        if (sLGMotionDisplayLink && sLGMotionDisplayLink.paused) {
            dispatch_async(dispatch_get_main_queue(), ^{
                sLGMotionDisplayLink.paused = NO;
            });
        }
    }];
    LGLog(@"motion highlights started reference=tilt+yaw rate=30Hz high-sensitivity");
}

static void LGEnsureMotionHighlights(void) {
    if (!LGIsSpringBoardBundle()) return;
    if (!sLGMotionGlasses) sLGMotionGlasses = [NSHashTable weakObjectsHashTable];
    if (!sLGMotionManager) sLGMotionManager = [CMMotionManager new];
    if (!sLGMotionSetup) {
        sLGMotionSetup = YES;
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        LGMotionPreferencesDidChange,
                                        kLGMotionPrefsReloadNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    LGReloadMotionHighlightPreferences();
    LGRefreshMotionHighlights();
}

static const CGFloat kLGGlassEdgeWidth = 1.0;

@implementation LGLiveBackdropView {
    NSString        *_lgGroupName;
    CAGradientLayer *_specularLayer;
    CAShapeLayer    *_specularMask;
    CAShapeLayer    *_edge;
    UIView          *_nativeBlurView;
    LGFallbackMaterialView *_fallbackMaterialView;
    LGKitGlassView  *_kitGlassView;
    BOOL             _captureEnabled;
    BOOL             _captureStateApplied;
    CGFloat          _nativeBlurRadius;
    BOOL             _backdropConfigured;
    BOOL             _filterAttached;
    uint32_t         _lgId;
    CGFloat          _appliedScale;
    CGFloat          _appliedBackdropZoom;
    BOOL             _parameterRefreshVariant;
    NSInteger        _lastRadiusStep;
    CGFloat          _appliedSpecularOpacity;
}

- (NSString *)lgEffectiveFilterType {
    if (!_lgFilterType.length)
        return [NSString stringWithUTF8String:kLGHostRegistry[LGHostIdentifierDefault].filterType];
    NSString *base = _lgFilterType;

    if (LGUsesDynamicRadiusType(base) && !CGRectIsEmpty(self.bounds)) {
        CGFloat shortest = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
        BOOL keyboard = LGHostIdentifierForFilterType(base.UTF8String) ==
            LGHostIdentifierKeyboard;
        CGFloat radius = keyboard ? _lgShapeCornerRadius : self.layer.cornerRadius;
        CGFloat ratio = shortest > 0.0 ? radius / shortest : 0.0;
        CGFloat exact = MAX(0.0, MIN(0.5, ratio)) * kLGDynamicRadiusSteps;
        NSInteger step = (NSInteger)llround(exact);
        if (_lastRadiusStep >= 0 && fabs(exact - (CGFloat)_lastRadiusStep) < 0.75)
            step = _lastRadiusStep;
        _lastRadiusStep = step;
        base = [base stringByAppendingFormat:@".r%ld", (long)step];
    }
    NSString *type = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [base stringByAppendingString:@".dark"] : base;
    if (_parameterRefreshVariant) type = [type stringByAppendingString:@".refresh"];
    return type;
}

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame groupName:nil filterType:nil];
}

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName {
    return [self initWithFrame:frame groupName:groupName filterType:nil];
}

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName filterType:(NSString *)filterType {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _lastRadiusStep = -1;
    _appliedSpecularOpacity = -1.0;
    _lgShapeRect = CGRectNull;
    _lgFilterType = [filterType copy];
    static atomic_uint idCounter = 0;
    _lgId = atomic_fetch_add(&idCounter, 1) + 1;
    if (groupName.length) {
        _lgGroupName = [groupName copy];
    } else {
        static uint32_t salt = 0;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ salt = arc4random(); });
        _lgGroupName = [NSString stringWithFormat:@"dylv.liquidglass.p%d.%08x.g%u",
                                                  getpid(), salt, _lgId];
    }
    self.userInteractionEnabled = NO;
    self.backgroundColor        = [UIColor clearColor];
    self.opaque                 = NO;

    self.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    LGEnsureFilterRefreshObserver();
    [sLGAllGlasses addObject:self];
    LGEnsureMotionHighlights();
    [sLGMotionGlasses addObject:self];
    [self applyFilters];
    return self;
}

- (void)dealloc {
    [sLGAllGlasses removeObject:self];
    [sLGMotionGlasses removeObject:self];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyFilters];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        _filterAttached = NO;
        [self applyFilters];
        [self updateSpecular];
        }
}

- (NSNumber *)lgSpecularEnabledOverride {
    return objc_getAssociatedObject(self, kLGSpecularEnabledOverrideKey);
}

- (void)setLgSpecularEnabledOverride:(NSNumber *)override {
    NSNumber *previous = self.lgSpecularEnabledOverride;
    if ((previous == override) || [previous isEqualToNumber:override]) return;
    objc_setAssociatedObject(self, kLGSpecularEnabledOverrideKey, [override copy],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self updateSpecular];
}

- (void)layoutSubviews  { [super layoutSubviews];  [self applyFilters]; [self updateSpecular]; }

- (void)updateNativeBlurOverlayWithRadius:(CGFloat)radius {
    if (radius <= 0.0) {
        [_nativeBlurView removeFromSuperview];
        _nativeBlurView = nil;
        _nativeBlurRadius = 0.0;
        return;
    }

    if (!_nativeBlurView) {
        Class blurClass = NSClassFromString(@"LGSettingsLowBlurView");
        if (!blurClass) return;
        _nativeBlurView = [[blurClass alloc] initWithFrame:self.bounds];
        _nativeBlurView.userInteractionEnabled = NO;
        [self insertSubview:_nativeBlurView atIndex:0];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _nativeBlurView.frame = self.bounds;
    _nativeBlurView.layer.cornerRadius = self.layer.cornerRadius;
    LGLayerCopyCornerStyle(_nativeBlurView.layer, self.layer);
    _nativeBlurView.clipsToBounds = YES;
    if (fabs(_nativeBlurRadius - radius) > 0.001) {
        @try { [_nativeBlurView setValue:@(radius) forKey:@"lgBlurRadius"]; }
        @catch (__unused NSException *exception) {}
        _nativeBlurRadius = radius;
    }
    [CATransaction commit];
}

- (UIColor *)lgFallbackTintForHost:(const LGHostDefinition *)host clear:(BOOL)clear {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    CGFloat rgba[4] = { dark ? 0.0 : 1.0, dark ? 0.0 : 1.0, dark ? 0.0 : 1.0, 0.0 };
    NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
    id configured = LGGlassPreferenceValue([prefix stringByAppendingString:
        dark ? @".DarkTintColor" : @".LightTintColor"]);
    if (!LGParseTintHex(configured, rgba))
        LGParseTintHex([NSString stringWithUTF8String:dark ? host->darkTintHex : host->lightTintHex], rgba);
    if (rgba[3] <= 0.001) {
        rgba[0] = rgba[1] = rgba[2] = dark ? 0.0 : 1.0;
    }
    if (UIAccessibilityIsReduceTransparencyEnabled()) {
        if (rgba[3] < 0.5) rgba[0] = rgba[1] = rgba[2] = dark ? 0.11 : 0.96;
        rgba[3] = 1.0;
    } else if (!clear) {
        CGFloat floor = dark ? 0.45 : 0.55;
        CGFloat area = CGRectGetWidth(self.bounds) * CGRectGetHeight(self.bounds);
        if (area > 40000.0) floor += 0.12;
        rgba[3] = MAX(rgba[3], floor);
    }
    return [UIColor colorWithRed:rgba[0] green:rgba[1] blue:rgba[2] alpha:rgba[3]];
}

- (UIColor *)lgKitTintForHost:(const LGHostDefinition *)host clear:(BOOL)clear {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
    CGFloat rgba[4];
    id configured = LGGlassPreferenceValue([prefix stringByAppendingString:
        dark ? @".DarkTintColor" : @".LightTintColor"]);
    if (!LGParseTintHex(configured, rgba)) {
        if (!clear) {
            return dark ? [UIColor colorWithRed:0.0 green:0.04958364581 blue:0.09951775161 alpha:0.7981493615]
                        : [UIColor colorWithRed:0.9023525731 green:0.9509486998 blue:1.0 alpha:0.8002892298];
        }
        LGParseTintHex([NSString stringWithUTF8String:dark ? host->darkTintHex : host->lightTintHex], rgba);
    }
    return [UIColor colorWithRed:rgba[0] green:rgba[1] blue:rgba[2] alpha:rgba[3]];
}

- (BOOL)updateKitGlass {
    const LGHostDefinition *host = LGHostDefinitionForFilterType(
        (_lgFilterType ?: [NSString stringWithUTF8String:kLGHostRegistry[LGHostIdentifierDefault].filterType]).UTF8String);
    enum LGHostIdentifier identifier = LGHostIdentifierForDefinition(host);
    if (!host || !LGKitEngineWanted(identifier) || ![LGKitGlassView lgEngineAvailable]) {
        if (_kitGlassView) {
            [_kitGlassView removeFromSuperview];
            _kitGlassView = nil;
            LGLog(@"glass#%u LiquidGlassKit engine detached type=%@", _lgId, _lgFilterType ?: @"default");
        }
        return NO;
    }
    if (CGRectIsEmpty(self.bounds)) return YES;
    if (!_kitGlassView) {
        _kitGlassView = [[LGKitGlassView alloc] initWithFrame:self.bounds];
        if (!_kitGlassView) return NO;
        _kitGlassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self insertSubview:_kitGlassView atIndex:0];
        LGLog(@"glass#%u LiquidGlassKit engine attached type=%@", _lgId, _lgFilterType ?: @"default");
    }

    BOOL clear = LGHostIsClearVariant(identifier);
    NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
    LGKitGlassParameters parameters = LGKitGlassParametersRegular;
    CGFloat value = 0.0;
    if (LGHostPreferenceNumber(prefix, @".BezelWidth", &value))
        parameters.glassThickness = MAX(2.0, MIN(40.0, value * 0.5));
    if (LGHostPreferenceNumber(prefix, @".RefractiveIndex", &value))
        parameters.refractiveIndex = 1.0 + MAX(0.01, value - 1.0) * 0.625;
    if (LGHostPreferenceNumber(prefix, @".DispersionStrength", &value))
        parameters.dispersionStrength = MAX(0.0, value) * 2.5;
    if (LGHostPreferenceNumber(prefix, @".DispersionEnabled", &value) && value == 0.0)
        parameters.dispersionStrength = 0.0;
    if (LGHostPreferenceNumber(prefix, @".Blur", &value))
        parameters.backgroundTextureBlurRadius = MAX(0.0, value) * 0.3;
    else if (clear)
        parameters.backgroundTextureBlurRadius = 0.0;
    if (clear) parameters.backgroundTextureScaleCoefficient = 0.5;
    NSNumber *override = self.lgSpecularEnabledOverride;
    BOOL specular = override ? override.boolValue : LGSpecularEnabledForFilterType(_lgFilterType);
    if (!specular) parameters.glareIntensity = 0.0;

    BOOL hasShape = !CGRectIsNull(_lgShapeRect) && !CGRectIsEmpty(_lgShapeRect);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!CGRectEqualToRect(_kitGlassView.frame, self.bounds)) _kitGlassView.frame = self.bounds;
    [CATransaction commit];
    _kitGlassView.lgParameters = parameters;
    _kitGlassView.lgShapeRect = hasShape ? _lgShapeRect : CGRectNull;
    _kitGlassView.lgCornerRadius = hasShape ? _lgShapeCornerRadius : self.layer.cornerRadius;
    _kitGlassView.lgTintColor = [self lgKitTintForHost:host clear:clear];
    _kitGlassView.lgGlareDirectionOffset = sLGSpecularAngle;
    _kitGlassView.preferredFramesPerSecond = LGQualityValue() >= 0.75 ? 60 : 30;
    return YES;
}

- (BOOL)updateFallbackMaterial {
    const LGHostDefinition *host = LGHostDefinitionForFilterType(
        (_lgFilterType ?: [NSString stringWithUTF8String:kLGHostRegistry[LGHostIdentifierDefault].filterType]).UTF8String);
    enum LGHostIdentifier identifier = LGHostIdentifierForDefinition(host);
    BOOL wanted = host && LGHostUsesFallbackMaterial(identifier) &&
        (UIAccessibilityIsReduceTransparencyEnabled() || !LGRendererCompositing());
    if (!wanted || CGRectIsEmpty(self.bounds)) {
        if (_fallbackMaterialView) {
            [_fallbackMaterialView removeFromSuperview];
            _fallbackMaterialView = nil;
        }
        return wanted;
    }
    BOOL clear = LGHostIsClearVariant(identifier);
    if (!_fallbackMaterialView) {
        _fallbackMaterialView = [[LGFallbackMaterialView alloc] initWithFrame:self.bounds];
        [self insertSubview:_fallbackMaterialView atIndex:0];
    }
    BOOL hasShape = !CGRectIsNull(_lgShapeRect) && !CGRectIsEmpty(_lgShapeRect);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fallbackMaterialView.frame = hasShape ? _lgShapeRect : self.bounds;
    _fallbackMaterialView.layer.cornerRadius = hasShape ? _lgShapeCornerRadius : self.layer.cornerRadius;
    LGLayerCopyCornerStyle(_fallbackMaterialView.layer, self.layer);
    [CATransaction commit];
    CGFloat radius = clear ? MAX(2.0, host->blur) : MAX(30.0, LGNativeBlurRadiusForFilterType(_lgFilterType));
    [_fallbackMaterialView lgApplyBlurRadius:radius
                                  saturation:clear ? 1.2 : 1.8
                                        tint:[self lgFallbackTintForHost:host clear:clear]];
    return YES;
}

- (void)setLgShapeRect:(CGRect)rect {
    if (CGRectEqualToRect(_lgShapeRect, rect)) return;
    _lgShapeRect = rect;
    if (LGHostIdentifierForFilterType(_lgFilterType.UTF8String) ==
        LGHostIdentifierKeyboard) {
        _filterAttached = NO;
        [self applyFilters];
    }
    [self updateSpecular];
}

- (void)setLgShapeCornerRadius:(CGFloat)radius {
    if (fabs(_lgShapeCornerRadius - radius) < 0.01) return;
    _lgShapeCornerRadius = radius;
    if (LGHostIdentifierForFilterType(_lgFilterType.UTF8String) ==
        LGHostIdentifierKeyboard) {
        _filterAttached = NO;
        [self applyFilters];
    }
    [self updateSpecular];
}

- (void)updateSpecular {
    if (CGRectIsEmpty(self.bounds)) return;
    if (_kitGlassView) {
        _specularLayer.hidden = YES;
        _edge.hidden = YES;
        [self updateKitGlass];
        return;
    }

    BOOL hasShape = !CGRectIsNull(_lgShapeRect) && !CGRectIsEmpty(_lgShapeRect);
    CGRect shapeRect = hasShape ? _lgShapeRect : self.bounds;
    CGFloat shapeRadius = hasShape ? _lgShapeCornerRadius
                                   : self.layer.cornerRadius;

    NSNumber *override = self.lgSpecularEnabledOverride;
    BOOL enabled = override ? override.boolValue
                            : LGSpecularEnabledForFilterType(_lgFilterType);
    const LGHostDefinition *host = LGHostDefinitionForFilterType(_lgFilterType.UTF8String);
    if (host == &kLGHostRegistry[LGHostIdentifierClock]) return;
    if (!enabled && !_specularLayer) return;

    if (!_edge) {
        _edge = [CAShapeLayer layer];
        _edge.backgroundColor = UIColor.clearColor.CGColor;
        _edge.borderWidth = kLGGlassEdgeWidth;
        [self.layer addSublayer:_edge];
    }

    CGFloat maxAlpha = 0.35;
    if (host) {
        NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
        id value = prefix.length
            ? LGGlassPreferenceValue([prefix stringByAppendingString:@".SpecularOpacity"])
            : nil;
        if ([value respondsToSelector:@selector(doubleValue)])
            maxAlpha = [value doubleValue];
        else if (host->specularOpacity > 0.001f)
            maxAlpha = host->specularOpacity;
    }
    maxAlpha = fmax(0.0, fmin(1.0, maxAlpha));

    if (!_specularLayer) {
        _specularLayer = [CAGradientLayer layer];
        _specularLayer.locations = @[@0.0, @0.12, @0.34, @0.66, @0.88, @1.0];
        _specularMask = [CAShapeLayer layer];
        _specularMask.backgroundColor = UIColor.clearColor.CGColor;
        _specularMask.borderColor = UIColor.blackColor.CGColor;
        _specularMask.borderWidth = 1.0;
        _specularLayer.mask = _specularMask;
        [self.layer addSublayer:_specularLayer];
    }
    if (fabs(_appliedSpecularOpacity - maxAlpha) > 0.001) {
        id clear = (id)UIColor.clearColor.CGColor;
        _specularLayer.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:maxAlpha * 0.28].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:maxAlpha * 0.10].CGColor,
            clear, clear,
            (id)[UIColor colorWithWhite:0.0 alpha:maxAlpha * 0.04].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:maxAlpha * 0.12].CGColor
        ];
        _appliedSpecularOpacity = maxAlpha;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _specularLayer.hidden = !enabled;
    _specularLayer.frame = shapeRect;
    UIColor *edgeColor = LGResolvedColor([LGSeparatorColor() colorWithAlphaComponent:0.16], self.traitCollection);
    _edge.hidden = NO;
    _edge.frame = shapeRect;
    _edge.cornerRadius = shapeRadius;
    LGLayerCopyCornerStyle(_edge, self.layer);
    _edge.borderWidth = kLGGlassEdgeWidth;
    _edge.borderColor = edgeColor.CGColor;

    _specularMask.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(shapeRect),
                                     CGRectGetHeight(shapeRect));
    _specularMask.cornerRadius = shapeRadius;
    LGLayerCopyCornerStyle(_specularMask, self.layer);
    _specularMask.borderWidth = 1.0;
    [CATransaction commit];
    [self applySpecularAngle:sLGSpecularAngle];
}

- (void)applySpecularAngle:(CGFloat)angle {
    _kitGlassView.lgGlareDirectionOffset = angle;
    if (!_specularLayer) return;
    CGFloat dx = cos(angle) * 0.5;
    CGFloat dy = sin(angle) * 0.5;
    _specularLayer.startPoint = CGPointMake(0.5 + dx, 0.5 + dy);
    _specularLayer.endPoint = CGPointMake(0.5 - dx, 0.5 - dy);
}

- (void)applyFilters {
    CALayer *layer = self.layer;
    Class backdropCls = NSClassFromString(@"CABackdropLayer");
    if (!backdropCls || ![layer isKindOfClass:backdropCls]) return;

    @try {

        if (!_backdropConfigured) {
            // these private flags keep capture in render server space
            LGLayerSetValueIfSupported(layer, @"layerUsesCoreImageFilters", @NO);
            LGLayerSetValueIfSupported(layer, @"windowServerAware", @NO);
            [layer setValue:_lgGroupName forKey:@"groupName"];
            if (!LGLayerSetValueIfSupported(layer, @"groupNamespace", @"dylv.liquidglass")) {
                LGLayerSetValueIfSupported(layer, @"usesGlobalGroupNamespace", @NO);
            }

            LGLayerSetValueIfSupported(layer, @"ignoresScreenClip", @YES);
            _backdropConfigured = YES;
        }

        if ([self updateKitGlass]) {
            if (_fallbackMaterialView) {
                [_fallbackMaterialView removeFromSuperview];
                _fallbackMaterialView = nil;
            }
            [self updateNativeBlurOverlayWithRadius:0.0];
            if (_captureEnabled || !_captureStateApplied) {
                LGLayerSetValueIfSupported(layer, @"enabled", @NO);
                _captureEnabled = NO;
                _captureStateApplied = YES;
            }
            if (layer.filters.count) layer.filters = nil;
            _filterAttached = NO;
            _specularLayer.hidden = YES;
            _edge.hidden = YES;
            return;
        }

        CGFloat wantScale;
        enum LGHostIdentifier hostIdentifier =
            LGHostIdentifierForFilterType(_lgFilterType.UTF8String);
        if (hostIdentifier == LGHostIdentifierClock) {
            wantScale = kLGClockCaptureScale;
        } else if (hostIdentifier == LGHostIdentifierCoverSheet ||
                   hostIdentifier == LGHostIdentifierTabBar ||
                   hostIdentifier == LGHostIdentifierTabBarSelection) {
            wantScale = 1.0;
        } else {
            wantScale = LGUsesPrefsControlCaptureScale(_lgFilterType)
                ? kLGPrefsControlScale : LGScaleForSize(self.bounds.size);
        }
        CGFloat wantZoom = _lgBackdropZoom > 0.0 ? _lgBackdropZoom : 1.0;
        BOOL zoomRelevant = fabs(wantZoom - 1.0) > 0.001 || _appliedBackdropZoom > 0.0;
        if (zoomRelevant && fabs(wantZoom - _appliedBackdropZoom) > 0.001) {
            _appliedBackdropZoom = wantZoom;
            @try { [layer setValue:@(wantZoom) forKey:@"zoom"]; }
            @catch (__unused NSException *exception) {}
            LGLog(@"glass#%u zoom type=%@ want=%.3f readback=%@", _lgId,
                  _lgFilterType ?: @"default", wantZoom,
                  [layer valueForKey:@"zoom"] ?: @"<none>");
        }

        if (fabs(wantScale - _appliedScale) > 0.02) {
            [layer setValue:@(wantScale) forKey:@"scale"];
            _appliedScale = wantScale;
        }

        NSString *wantType = [self lgEffectiveFilterType];
        NSArray *existing = layer.filters;
        Class filterCls = NSClassFromString(@"CAFilter");
        BOOL fallbackMaterial = [self updateFallbackMaterial];
        [self updateNativeBlurOverlayWithRadius:fallbackMaterial ? 0.0 :
            LGNativeBlurRadiusForFilterType(_lgFilterType ?: wantType)];

        BOOL captureEnabled = !(fallbackMaterial && LGRendererUnavailable());
        if (_captureEnabled != captureEnabled || !_captureStateApplied) {
            LGLayerSetValueIfSupported(layer, @"enabled", @(captureEnabled));
            _captureEnabled = captureEnabled;
            _captureStateApplied = YES;
        }
        if (!captureEnabled) {
            if (existing.count) layer.filters = nil;
            _filterAttached = NO;
            return;
        }

        if (_filterAttached && existing.count == 1) {
            NSString *type = nil;
            @try { type = [existing.firstObject valueForKey:@"type"]; } @catch (...) {}
            if ([type isEqualToString:wantType]) {
                return;
            }
        }
        if (!filterCls) { sblog("CAFilter class not found"); return; }

        id glassFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), wantType);

        if (!glassFilter) {
            LGLog(@"glass#%u filterWithType nil (not registered yet?)", _lgId);
            return;
        }

        if (LGNeedsGaussianIdentityFallback()) {
            @try { [glassFilter setValue:@1.0 forKey:@"inputRadius"]; }
            @catch (...) {}
        }

        layer.filters = @[glassFilter];
        _filterAttached = YES;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"LGLiveBackdropViewFilterDidAttach" object:self];
    } @catch (NSException *e) {
        sblog("applyFilters exception: %s", e.reason.UTF8String);
    }
}

- (void)reapplyFilterForParameterReload {

    _parameterRefreshVariant = !_parameterRefreshVariant;

    _appliedScale = -1.0;
    _filterAttached = NO;
    [self applyFilters];
    [self updateSpecular];
    [self.layer setNeedsDisplay];
    [_specularLayer setNeedsDisplay];
}

- (void)lgInvalidateFilterContents {
    _parameterRefreshVariant = !_parameterRefreshVariant;
    _filterAttached = NO;
    [self applyFilters];
    [self.layer setNeedsDisplay];
}

- (BOOL)lgFilterAttached {
    return _filterAttached;
}

@end

#pragma mark - generic host injection

static CGRect LGOutsetFrame(CGRect mf, UIEdgeInsets outset) {
    return CGRectMake(mf.origin.x - outset.left,
                      mf.origin.y - outset.top,
                      mf.size.width  + outset.left + outset.right,
                      mf.size.height + outset.top  + outset.bottom);
}

void LGInjectGlassIntoMaterialGroupType(UIView *mat, const void *assocKey,
                                        UIEdgeInsets outset, CGFloat cornerRadius,
                                        NSString *groupName, NSString *filterType) {
    UIView *parent = mat.superview;
    if (!parent) return;

    CGRect gf = LGOutsetFrame(mat.frame, outset);

    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) {
        glass = [[LGLiveBackdropView alloc] initWithFrame:gf groupName:groupName filterType:filterType];
        __weak LGLiveBackdropView *weakGlass = glass;
        for (NSNumber *delay in @[ @1.5, @3.0, @5.0, @8.0, @12.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakGlass applyFilters];
            });
        }
        [parent insertSubview:glass aboveSubview:mat];
        objc_setAssociatedObject(mat, assocKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != parent) [parent insertSubview:glass aboveSubview:mat];
    CGFloat radius = (cornerRadius >= 0.0) ? cornerRadius : mat.layer.cornerRadius;
    if (!CGRectEqualToRect(glass.frame, gf))          glass.frame              = gf;
    if (fabs(glass.layer.cornerRadius - radius) > 0.5) {
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];
        [glass applyFilters];
    }
    LGLayerSetContinuousCorners(glass.layer);
    glass.layer.masksToBounds = YES;

    objc_setAssociatedObject(glass, kLGOutsetKey, [NSValue valueWithUIEdgeInsets:outset],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(glass, kLGRadiusKey, @(cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!mat.hidden) mat.hidden = YES;
}

static void LGSyncGlassGeometry(UIView *mat, const void *assocKey,
                                UIEdgeInsets outset, CGFloat cornerRadius);

void LGResyncGlassGeometry(UIView *mat, const void *assocKey) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    NSValue *ov  = objc_getAssociatedObject(glass, kLGOutsetKey);
    NSNumber *rv = objc_getAssociatedObject(glass, kLGRadiusKey);
    LGSyncGlassGeometry(mat, assocKey, ov ? ov.UIEdgeInsetsValue : UIEdgeInsetsZero,
                        rv ? rv.doubleValue : -1.0);
}

static void LGSyncGlassGeometry(UIView *mat, const void *assocKey,
                                UIEdgeInsets outset, CGFloat cornerRadius) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    CGRect gf = LGOutsetFrame(mat.frame, outset);
    CGFloat radius = (cornerRadius >= 0.0) ? cornerRadius : mat.layer.cornerRadius;

    if (!CGRectEqualToRect(glass.frame, gf)) {
        glass.frame = gf;
    }
    if (fabs(glass.layer.cornerRadius - radius) > 0.5) {
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];
        [glass applyFilters];
    }
    if (!mat.hidden) mat.hidden = YES;
}

void LGRemoveGlassFromMaterial(UIView *mat, const void *assocKey) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    objc_setAssociatedObject(mat, assocKey, nil, OBJC_ASSOCIATION_ASSIGN);
    mat.hidden = NO;

    [glass removeFromSuperview];
}

BOOL LGMaterialHasGlass(UIView *mat, const void *assocKey) {
    return objc_getAssociatedObject(mat, assocKey) != nil;
}
