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
    CGFloat backgroundTextureScaleCoefficient;
    CGFloat backgroundTextureBlurRadius;
} LGKitGlassParameters;

// LiquidGlassKit "regular" preset.
FOUNDATION_EXTERN const LGKitGlassParameters LGKitGlassParametersRegular;

// In-process port of LiquidGlassKit's LiquidGlassView: a CABackdropLayer sibling is
// snapshotted with drawViewHierarchyInRect into an IOSurface-backed texture, blurred
// with MPS and run through the SDF refraction / fresnel / glare fragment shader.
@interface LGKitGlassView : MTKView

+ (BOOL)lgEngineAvailable;

- (instancetype)initWithFrame:(CGRect)frame;

@property (nonatomic, assign) LGKitGlassParameters lgParameters;
@property (nonatomic, strong) UIColor *lgTintColor;
@property (nonatomic, assign) CGRect lgShapeRect;
@property (nonatomic, assign) CGFloat lgCornerRadius;
@property (nonatomic, assign) CGFloat lgGlareDirectionOffset;

@end
