Shader "LTCGI/Surface (APIv2) URP"
{
    Properties
    {
        _Color ("Color", Color) = (1,1,1,1)
        _MainTex ("Albedo (RGB)", 2D) = "white" {}
        [HideInInspector] _LightMap ("(for surface ST only)", 2D) = "white" {}
        _BumpMap ("Normal Map", 2D) = "bump" {}
        _BumpScale ("Normal Scale", Float) = 1.0
        _Metallic ("Metallic", Range(0,1)) = 0.0
        _Glossiness ("Smoothness", Range(0,1)) = 0.5
        _GlossinessMap ("Smoothness Map", 2D) = "white" {}
        [ToggleUI] _MapIsRoughness ("Invert Smoothness Map", Float) = 0.0

        [ToggleUI] _LTCGI ("LTCGI enabled", Float) = 1.0
        _LTCGI_DiffuseColor ("LTCGI Diffuse Color", Color) = (1,1,1,1)
        _LTCGI_SpecularColor ("LTCGI Specular Color", Color) = (1,1,1,1)
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
            "RenderPipeline" = "UniversalPipeline"
            "UniversalMaterialType" = "Lit"
            "LTCGI" = "_LTCGI"
            "IgnoreProjector" = "True"
        }
        LOD 200

        // UnityPerMaterial layout must be identical across every pass or the SRP Batcher
        // silently disables batching for this material.
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

        CBUFFER_START(UnityPerMaterial)
            float4 _MainTex_ST;
            float4 _BumpMap_ST;
            float4 _GlossinessMap_ST;
            half4  _Color;
            half   _Metallic;
            half   _Glossiness;
            half   _BumpScale;
            float  _MapIsRoughness;
            float  _LTCGI;
            half4  _LTCGI_DiffuseColor;
            half4  _LTCGI_SpecularColor;
        CBUFFER_END

        TEXTURE2D(_MainTex);        SAMPLER(sampler_MainTex);
        TEXTURE2D(_BumpMap);        SAMPLER(sampler_BumpMap);
        TEXTURE2D(_GlossinessMap);  SAMPLER(sampler_GlossinessMap);
        ENDHLSL

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

            Cull Back
            ZTest LEqual
            ZWrite On

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex   LitPassVertex
            #pragma fragment LitPassFragment

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _SCREEN_SPACE_OCCLUSION
            #pragma multi_compile _ LIGHTMAP_SHADOW_MIXING
            #pragma multi_compile _ SHADOWS_SHADOWMASK
            #pragma multi_compile _ DIRLIGHTMAP_COMBINED
            #pragma multi_compile _ LIGHTMAP_ON
            #pragma multi_compile _ DYNAMICLIGHTMAP_ON
            #pragma multi_compile_fragment _ _LIGHT_LAYERS
            #pragma multi_compile_fragment _ _LIGHT_COOKIES
            #pragma multi_compile _ _FORWARD_PLUS
            #pragma multi_compile_fog
            #pragma multi_compile_instancing
            #pragma instancing_options renderinglayer

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // APIv2: accumulator + forward-declared callbacks must exist before LTCGI.cginc is included.
            #include "Packages/at.pimaker.ltcgi/Shaders/LTCGI_structs.cginc"

            struct accumulator_struct
            {
                float3 diffuse;
                float3 specular;
            };
            void callback_diffuse (inout accumulator_struct acc, in ltcgi_output o);
            void callback_specular(inout accumulator_struct acc, in ltcgi_output o);

            #define LTCGI_V2_CUSTOM_INPUT      accumulator_struct
            #define LTCGI_V2_DIFFUSE_CALLBACK  callback_diffuse
            #define LTCGI_V2_SPECULAR_CALLBACK callback_specular

            #include "Packages/at.pimaker.ltcgi/Shaders/LTCGI_URP_Compat.hlsl"
            #include "Packages/at.pimaker.ltcgi/Shaders/LTCGI.cginc"

            void callback_diffuse(inout accumulator_struct acc, in ltcgi_output o)
            {
                acc.diffuse += o.intensity * o.color * _LTCGI_DiffuseColor.rgb;
            }
            void callback_specular(inout accumulator_struct acc, in ltcgi_output o)
            {
                acc.specular += o.intensity * o.color * _LTCGI_SpecularColor.rgb;
            }

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
                float2 uv0        : TEXCOORD0;
                float2 uv1        : TEXCOORD1; // static lightmap / LTCGI lmuv
                float2 uv2        : TEXCOORD2; // dynamic lightmap
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                float3 normalWS   : TEXCOORD1;
                float4 tangentWS  : TEXCOORD2; // .w = sign for bitangent
                float2 uv         : TEXCOORD3;
                float2 lmRawUV    : TEXCOORD4; // raw uv1 for LTCGI lightmap sampling
                DECLARE_LIGHTMAP_OR_SH(staticLightmapUV, vertexSH, 5);
                #ifdef DYNAMICLIGHTMAP_ON
                    float2 dynamicLightmapUV : TEXCOORD6;
                #endif
                float fogCoord : TEXCOORD7;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings LitPassVertex(Attributes input)
            {
                Varyings o = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                VertexPositionInputs vp = GetVertexPositionInputs(input.positionOS.xyz);
                VertexNormalInputs   vn = GetVertexNormalInputs(input.normalOS, input.tangentOS);

                o.positionCS = vp.positionCS;
                o.positionWS = vp.positionWS;
                o.normalWS   = vn.normalWS;
                o.tangentWS  = float4(vn.tangentWS, input.tangentOS.w * GetOddNegativeScale());
                o.uv         = TRANSFORM_TEX(input.uv0, _MainTex);
                o.lmRawUV    = input.uv1;
                o.fogCoord   = ComputeFogFactor(vp.positionCS.z);

                OUTPUT_LIGHTMAP_UV(input.uv1, unity_LightmapST, o.staticLightmapUV);
                OUTPUT_SH(vn.normalWS, o.vertexSH);
                #ifdef DYNAMICLIGHTMAP_ON
                    o.dynamicLightmapUV = input.uv2 * unity_DynamicLightmapST.xy + unity_DynamicLightmapST.zw;
                #endif
                return o;
            }

            half4 LitPassFragment(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                half4 albedo  = SAMPLE_TEXTURE2D(_MainTex,       sampler_MainTex,       input.uv) * _Color;
                half  smooth  = SAMPLE_TEXTURE2D(_GlossinessMap, sampler_GlossinessMap, input.uv).r;
                if (_MapIsRoughness > 0.5) smooth = 1.0h - smooth;
                smooth *= _Glossiness;

                half3 normalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, input.uv), _BumpScale);

                float3 bitangentWS = cross(input.normalWS, input.tangentWS.xyz) * input.tangentWS.w;
                float3x3 tangentToWorld = float3x3(input.tangentWS.xyz, bitangentWS, input.normalWS);
                float3 normalWS = normalize(TransformTangentToWorld(normalTS, tangentToWorld));

                SurfaceData s = (SurfaceData)0;
                s.albedo              = albedo.rgb;
                s.metallic            = _Metallic;
                s.specular            = 0;
                s.smoothness          = smooth;
                s.normalTS            = normalTS;
                s.emission            = 0;
                s.occlusion           = 1;
                s.alpha               = 1;
                s.clearCoatMask       = 0;
                s.clearCoatSmoothness = 0;

                InputData lit = (InputData)0;
                lit.positionWS         = input.positionWS;
                lit.positionCS         = input.positionCS;
                lit.normalWS           = normalWS;
                lit.viewDirectionWS    = SafeNormalize(GetWorldSpaceViewDir(input.positionWS));
                #if defined(_MAIN_LIGHT_SHADOWS) && !defined(_RECEIVE_SHADOWS_OFF)
                    lit.shadowCoord    = TransformWorldToShadowCoord(input.positionWS);
                #else
                    lit.shadowCoord    = float4(0, 0, 0, 0);
                #endif
                lit.fogCoord           = InitializeInputDataFog(float4(input.positionWS, 1.0), input.fogCoord);
                lit.vertexLighting     = 0;
                #if defined(DYNAMICLIGHTMAP_ON)
                    lit.bakedGI = SAMPLE_GI(input.staticLightmapUV, input.dynamicLightmapUV, input.vertexSH, normalWS);
                #else
                    lit.bakedGI = SAMPLE_GI(input.staticLightmapUV, input.vertexSH, normalWS);
                #endif
                lit.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(input.positionCS);
                lit.shadowMask         = SAMPLE_SHADOWMASK(input.staticLightmapUV);
                #if defined(DEBUG_DISPLAY)
                    lit.vertexSH       = input.vertexSH;
                #endif

                half4 color = UniversalFragmentPBR(lit, s);

                if (_LTCGI > 0.5)
                {
                    accumulator_struct acc = (accumulator_struct)0;
                    LTCGI_Contribution(
                        acc,
                        input.positionWS,
                        normalWS,
                        normalize(LTCGI_GetCameraPosWS() - input.positionWS),
                        1.0h - smooth,
                        input.lmRawUV
                    );
                    color.rgb += acc.specular;
                    color.rgb += acc.diffuse * albedo.rgb;
                }

                color.rgb = MixFog(color.rgb, lit.fogCoord);
                return color;
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull Back

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex   ShadowPassVertex
            #pragma fragment ShadowPassFragment
            #pragma multi_compile_instancing
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            float3 _LightDirection;
            float3 _LightPosition;

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            float4 GetShadowPositionHClip(Attributes input)
            {
                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS   = TransformObjectToWorldNormal(input.normalOS);

                #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                    float3 lightDirectionWS = normalize(_LightPosition - positionWS);
                #else
                    float3 lightDirectionWS = _LightDirection;
                #endif

                float4 positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, lightDirectionWS));

                #if UNITY_REVERSED_Z
                    positionCS.z = min(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #else
                    positionCS.z = max(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #endif
                return positionCS;
            }

            Varyings ShadowPassVertex(Attributes input)
            {
                Varyings o = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.positionCS = GetShadowPositionHClip(input);
                return o;
            }

            half4 ShadowPassFragment(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                return 0;
            }
            ENDHLSL
        }

        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }

            ZWrite On
            ColorMask 0
            Cull Back

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex   DepthOnlyVertex
            #pragma fragment DepthOnlyFragment
            #pragma multi_compile_instancing

            struct Attributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings DepthOnlyVertex(Attributes input)
            {
                Varyings o = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                return o;
            }

            half4 DepthOnlyFragment(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                return 0;
            }
            ENDHLSL
        }

        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }

            ZWrite On
            Cull Back

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex   DepthNormalsVertex
            #pragma fragment DepthNormalsFragment
            #pragma multi_compile_instancing

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
                float2 uv         : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 normalWS   : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings DepthNormalsVertex(Attributes input)
            {
                Varyings o = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                o.normalWS   = TransformObjectToWorldNormal(input.normalOS);
                return o;
            }

            half4 DepthNormalsFragment(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                return half4(NormalizeNormalPerPixel(input.normalWS), 0);
            }
            ENDHLSL
        }
    }

    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
