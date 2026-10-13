#pragma once
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>

typedef struct {
    CGFloat glassThickness;
    CGFloat refractiveIndex;
    CGFloat dispersionStrength;
    CGFloat fresnelDistanceRange;
    CGFloat fresnelIntensity;
    CGFloat fresnelEdgeSharpness;
    CGFloat glareDistanceRange;
    CGFloat glareAngleConvergence;
    CGFloat glareOppositeSideBias;
    CGFloat glareIntensity;
    CGFloat glareEdgeSharpness;
    CGFloat glareDirectionOffset;
    CGFloat backgroundTextureSizeCoefficient;
    CGFloat backgroundTextureScaleCoefficient;
    CGFloat backgroundTextureBlurRadius;
    BOOL shadowOverlay;
} LGKitGlassParameters;

// LiquidGlassKit presets: LiquidGlassEffectView uses regular, LiquidGlassSlider
// thumb(1), LiquidGlassSwitch thumb(0.75) and LiquidLensView lens.
FOUNDATION_EXTERN LGKitGlassParameters LGKitGlassParametersRegular(void);
FOUNDATION_EXTERN LGKitGlassParameters LGKitGlassParametersThumb(CGFloat magnification);
FOUNDATION_EXTERN LGKitGlassParameters LGKitGlassParametersLens(void);
FOUNDATION_EXTERN UIColor *LGKitGlassRegularTint(BOOL dark);
FOUNDATION_EXTERN UIColor *LGKitGlassThumbTint(void);

// 1 GB A7/A8 class hardware.
FOUNDATION_EXTERN BOOL LGKitGlassLowMemoryDevice(void);

// In-process port of LiquidGlassKit's LiquidGlassView: a CABackdropLayer sibling is
// snapshotted with drawViewHierarchyInRect into an IOSurface-backed texture, blurred
// with MPS and run through the single-pass SDF refraction / fresnel / glare shader.
// Every instance is driven by one shared display link that re-captures stationary
// glass at a reduced rate and only re-renders when the capture or uniforms change.
@interface LGKitGlassView : MTKView

+ (BOOL)lgEngineAvailable;
+ (void)lgSetPreferredFramesPerSecond:(NSInteger)framesPerSecond;

- (instancetype)initWithFrame:(CGRect)frame;

@property (nonatomic, assign) LGKitGlassParameters lgParameters;
@property (nonatomic, strong) UIColor *lgTintColor;
@property (nonatomic, assign) CGRect lgShapeRect;
@property (nonatomic, assign) CGFloat lgCornerRadius;
@property (nonatomic, assign) CGFloat lgGlareDirectionOffset;
// Fraction of the screen scale used for the drawable (1 = native).
@property (nonatomic, assign) CGFloat lgDrawableScale;

@end
