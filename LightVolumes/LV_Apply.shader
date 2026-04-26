Shader "LTCGI/LV Apply (Blit)"
{
    Properties
    {
        _MainTex ("Base", 3D) = "black" {}
        _Directionality ("Directionality", Range(0.0, 1.0)) = 0.66
    }
    SubShader
    {
        Lighting Off
        Blend One Zero

        Pass
        {
            Name "LTCGI LV Apply"

            CGPROGRAM
            #define LTCGI_FAST_SAMPLING
            #include "UnityCustomRenderTexture.cginc"
            //#include "Packages/red.sim.lightvolumes/Shaders/LightVolumes.cginc" // open coded
            #include "Packages/at.pimaker.ltcgi/Shaders/LTCGI.cginc"

            #pragma vertex CustomRenderTextureVertexShader
            #pragma fragment frag
            #pragma target 3.0

            uniform Texture3D<float4> _MainTex;
            uniform SamplerState sampler_MainTex;

            uniform float _Directionality;

            // from Light Volume Manager
            uniform float4 _UdonLightVolumeUvwScale[96];
            uniform float _UdonLightVolumeEnabled;
            uniform float _UdonLightVolumeCount;

            // from LTCGI LV Adapter
            uniform float4x4 _UdonLightVolumeFwdWorldMatrix[32];
            uniform float _UdonLightVolumesWithLTCGI; // actually a uint used as bitfield

            // special data for LVs from LTCGI_Adapter
            uniform uint _Udon_LTCGI_ScreenCount_LVs;
            uniform bool _Udon_LTCGI_Mask_LVs[MAX_SOURCES];

            static float4 uvwPos[3];
            static float3 padding; // assumes padding stays 1 in Texture3DAtlasGenerator

            float3 UVWinvert(float3 uvw, float3 uvwScale, float3 uvwPos)
            {
                return ((uvw - uvwPos) / uvwScale) - 0.5;
            }

            float3 WorldFromVolume(uint volumeID, float3 localPos)
            {
                return mul(_UdonLightVolumeFwdWorldMatrix[volumeID], float4(localPos, 1.0)).xyz;
            }

            bool PointLocalInAABB(float3 localUVW, float3 uvwScale)
            {
                float3 localPadding = padding / uvwScale; // in my head this should be * 0.5, but then it has seams again 🤔
                return all(abs(localUVW) <= 0.5 + localPadding);
            }

            void BasicLTCGI(float3 worldPos, inout float3 L0, inout float3 L1r, inout float3 L1g, inout float3 L1b)
            {
                // backup backed values and reset output data
                float3 L0b = L0;
                float3 L1b_r = L1r;
                float3 L1b_g = L1g;
                float3 L1b_b = L1b;
                L0 = L1r = L1g = L1b = 0;

                #if MAX_SOURCES != 1
                    uint count = min(_Udon_LTCGI_ScreenCount_LVs, MAX_SOURCES);
                    [loop]
                #else
                    // mobile config
                    const uint count = 1;
                    [unroll(1)]
                #endif
                for (uint i = 0; i < count; i++) {
                    // skip masked and black lights
                    if (_Udon_LTCGI_Mask_LVs[i]) continue;
                    float4 extra = _Udon_LTCGI_ExtraData[i];
                    float3 color = extra.rgb;
                    if (!any(color)) continue;

                    ltcgi_flags flags = ltcgi_parse_flags(asuint(extra.w), true);
                    
                    #ifdef LTCGI_ALWAYS_LTC_DIFFUSE
                        // can't honor a lightmap-only light in this mode
                        if (flags.lmdOnly) continue;
                    #endif

                    #ifdef LTCGI_TOGGLEABLE_SPEC_DIFF_OFF
                        // compile branches below away statically
                        flags.diffuse = flags.specular = true;
                    #endif

                    if (!flags.diffuse) continue;

                    // calculate (shifted) world space positions
                    float3 Lw[4];
                    float4 uvStart = (float4)0, uvEnd = (float4)0;
                    bool isTri = false;
                    LTCGI_GetLw(i, flags, worldPos, Lw, uvStart, uvEnd, isTri);

                    // skip single-sided lights that face the other way
                    float3 screenNorm = cross(Lw[1] - Lw[0], Lw[2] - Lw[0]);
                    if (!flags.doublesided) {
                        if (dot(screenNorm, Lw[0]) < 0)
                            continue;
                    }

                    ltcgi_input input;
                    input.i = i;
                    input.Lw = Lw;
                    input.isTri = isTri;
                    input.uvStart = uvStart;
                    input.uvEnd = uvEnd;
                    input.rawColor = color;
                    input.flags = flags;
                    input.screenNormal = screenNorm;

                    // construct orthonormal basis around N by approximating view and normal dir as coming directly from the screen
                    float3 avgPos = (Lw[0] + Lw[1] + Lw[2] + Lw[3]) * 0.25f;
                    float3 worldNorm = normalize(screenNorm);
                    float3 viewDir = -normalize(avgPos);
                    float3 T1 = normalize(viewDir - worldNorm*dot(viewDir, worldNorm));
                    float3 T2 = cross(worldNorm, T1);
                    float3x3 identityBrdf = float3x3(float3(T1), float3(T2), float3(worldNorm));

                    ltcgi_output diff;
                    LTCGI_Evaluate(input, identityBrdf, 0, false, diff);

                    float l0ch = flags.lmch == 0 ? 1 : L0b[flags.lmch - 1];
                    float3 l1ch;
                    switch (flags.lmch)
                    {
                        case 1: l1ch = L1b_r; break;
                        case 2: l1ch = L1b_g; break;
                        case 3: l1ch = L1b_b; break;
                        default: l1ch = 0; break; // no channel (or 0 aka "off"), skips L1
                    }

                    float3 output = diff.color; // * diff.intensity; - Intensity is baked by LV
                    float l1dir = saturate(_Directionality - diff.intensity * 0.66f);
                    L0 += max(0, l0ch * output.rgb);
                    L1r += max(0, l1ch * output.r * l1dir);
                    L1g += max(0, l1ch * output.g * l1dir);
                    L1b += max(0, l1ch * output.b * l1dir);
                }
            }

            float4 frag(v2f_customrendertexture i) : COLOR
            {
                float3 uvw = i.globalTexcoord.xyz;
                float4 val = _MainTex.SampleLevel(sampler_MainTex, uvw, 0);

                if (!_UdonLightVolumeEnabled)
                    return val;

                // calculate padding from dimension side (one sample in texture space)
                uint3 dim = 0;
                _MainTex.GetDimensions(dim.x, dim.y, dim.z);
                padding = float3(1.0f / dim.x, 1.0f / dim.y, 1.0f / dim.z);

                uint ltcgiVolumes = asuint(_UdonLightVolumesWithLTCGI);

                uint volumesCount = clamp((uint) _UdonLightVolumeCount, 0, 32);
                [loop] for (uint id = 0; id < volumesCount; id++)
                {
                    if ((ltcgiVolumes & (1u << id)) == 0)
                        continue;

                    uint uvwID = id * 3;
                    uvwPos[0] = _UdonLightVolumeUvwScale[uvwID];
                    uvwPos[1] = _UdonLightVolumeUvwScale[uvwID + 1];
                    uvwPos[2] = _UdonLightVolumeUvwScale[uvwID + 2];
                    float3 uvwScale = float3(uvwPos[0].w, uvwPos[1].w, uvwPos[2].w);

                    [loop] for (uint level = 0; level < 3; level++)
                    {
                        float3 localUVW = UVWinvert(uvw, uvwScale, uvwPos[level].xyz);
                        if (PointLocalInAABB(localUVW, uvwScale))
                        {
                            /*
                                packed format (from LV code):
                                    L0 = tex0.rgb;
                                    L1r = float3(tex1.r, tex2.r, tex0.a);
                                    L1g = float3(tex1.g, tex2.g, tex1.a);
                                    L1b = float3(tex1.b, tex2.b, tex2.a);
                            */

                            float3 L0 = 0, L1r = 0, L1g = 0, L1b = 0;
                            [forcecase] switch (level)
                            {
                                case 0: L0.rgb = val.rgb; L1r.z = val.a; break;
                                case 1: L1r.x = val.r; L1g.xz = val.ga; L1b.x = val.b; break;
                                case 2: L1r.y = val.r; L1g.y = val.g; L1b.yz = val.ba; break;
                            }

                            float3 worldPos = WorldFromVolume(id, localUVW);
                            BasicLTCGI(worldPos, L0, L1r, L1g, L1b);

                            [forcecase] switch (level)
                            {
                                case 0: val.rgb = L0; val.a = L1r.z; break;
                                case 1: val.r = L1r.x; val.ga = L1g.xz; val.b = L1b.x; break;
                                case 2: val.r = L1r.y; val.g = L1g.y; val.ba = L1b.yz; break;
                            }

                            return val; // exit now, we found our target volume and applied LTCGI data
                        }
                    }
                }

                return val; // pass through unrelated data
            }
            ENDCG
        }
    }
}