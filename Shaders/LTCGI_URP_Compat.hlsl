#ifndef LTCGI_URP_COMPAT_INCLUDED
#define LTCGI_URP_COMPAT_INCLUDED

// URP shim for the Built-in RP cgincs that LTCGI ships.
// Include AFTER URP's Core.hlsl (and Lighting.hlsl for lit passes), BEFORE LTCGI.cginc.

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/EntityLighting.hlsl"

#ifndef fixed
    #define fixed  half
    #define fixed2 half2
    #define fixed3 half3
    #define fixed4 half4
#endif

#ifndef UNITY_PI
    #define UNITY_PI 3.14159265359f
#endif
#ifndef UNITY_HALF_PI
    #define UNITY_HALF_PI 1.57079632679f
#endif
#ifndef UNITY_TWO_PI
    #define UNITY_TWO_PI 6.28318530718f
#endif
#ifndef UNITY_FOUR_PI
    #define UNITY_FOUR_PI 12.56637061436f
#endif
#ifndef UNITY_INV_PI
    #define UNITY_INV_PI 0.31830988618f
#endif

// 1-arg overload bridging to URP's 2-arg DecodeLightmap.
real3 DecodeLightmap(real4 color)
{
#if defined(UNITY_LIGHTMAP_FULL_HDR)
    return color.rgb;
#else
    real4 decodeInstructions = real4(LIGHTMAP_HDR_MULTIPLIER, LIGHTMAP_HDR_EXPONENT, 0.0, 0.0);
    return DecodeLightmap(color, decodeInstructions);
#endif
}

// Reads _WorldSpaceCameraPos directly. Do NOT reconstruct from unity_CameraToWorld[].[3]
// like the BIRP shaders do — under SPI that returns the centered-eye position and breaks
// per-eye specular.
float3 LTCGI_GetCameraPosWS()
{
    return _WorldSpaceCameraPos;
}

#endif
