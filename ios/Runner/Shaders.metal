#include <metal_stdlib>
using namespace metal;

struct FilterUniforms { float dt, lowerHz, upperHz, gain; uint reset, luminanceOnly; };

// Multi-scale, gradient-domain Eulerian motion magnification. The temporal
// band-pass is evaluated on a Laplacian spatial signal, then brightness
// constancy converts that response into a sub-pixel displacement field. The
// source frame is warped by the amplified displacement, so motion appears as
// motion instead of the brightness pulsing produced by linear pixel addition.
// This follows the published phase/Eulerian family of motion-processing
// methods; it does not reproduce any proprietary vendor implementation.
// alpha(fc,dt) = 1 - exp(-2*pi*fc*dt)
// fast = fast + alpha(upper,dt)*(x-fast)
// slow = slow + alpha(lower,dt)*(x-slow)
// band = fast - slow; displacement ~= -band*gradient/(|gradient|^2+noise)
// Coefficients depend on camera timestamps, never frame counts. Temporal
// state is stored as R32Float by the host to retain tiny sub-pixel signals.

inline float luminance(float3 color) {
  return dot(color, float3(0.2126, 0.7152, 0.0722));
}

inline float lumaAt(texture2d<float, access::sample> input,
                    sampler s, float2 uv) {
  return luminance(input.sample(s, uv).rgb);
}

inline float crossBlur(texture2d<float, access::sample> input,
                       sampler s, float2 uv, float2 texel, float radius) {
  float2 d = texel * radius;
  return lumaAt(input, s, uv) * 0.40
       + (lumaAt(input, s, uv + float2(d.x, 0.0))
       +  lumaAt(input, s, uv - float2(d.x, 0.0))
       +  lumaAt(input, s, uv + float2(0.0, d.y))
       +  lumaAt(input, s, uv - float2(0.0, d.y))) * 0.15;
}

kernel void amplifyLuma(texture2d<float, access::sample> input [[texture(0)]],
                        texture2d<float, access::read_write> fastState [[texture(1)]],
                        texture2d<float, access::read_write> slowState [[texture(2)]],
                        texture2d<float, access::write> output [[texture(3)]],
                        constant FilterUniforms &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
  constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
  float2 size = float2(input.get_width(), input.get_height());
  float2 texel = 1.0 / size;
  float2 uv = (float2(gid) + 0.5) * texel;

  float center = lumaAt(input, s, uv);
  float blur1 = crossBlur(input, s, uv, texel, 1.0);
  float blur2 = crossBlur(input, s, uv, texel, 2.0);
  float blur4 = crossBlur(input, s, uv, texel, 4.0);
  // Three Laplacian-like scales improve SNR without erasing broad, slow
  // structural motion. Illumination common to the neighborhood is rejected.
  float signal = (center - blur1) * 0.50
               + (blur1 - blur2) * 0.32
               + (blur2 - blur4) * 0.18;
  float fast = p.reset != 0 ? signal : fastState.read(gid).r;
  float slow = p.reset != 0 ? signal : slowState.read(gid).r;
  if (p.reset == 0 && p.dt > 0) {
    float fastAlpha = 1.0 - exp(-2.0 * M_PI_F * p.upperHz * p.dt);
    float slowAlpha = 1.0 - exp(-2.0 * M_PI_F * p.lowerHz * p.dt);
    fast += fastAlpha * (signal - fast);
    slow += slowAlpha * (signal - slow);
  }
  fastState.write(float4(fast), gid);
  slowState.write(float4(slow), gid);

  float gx = 0.50 * (lumaAt(input, s, uv + float2(texel.x, 0.0))
                   - lumaAt(input, s, uv - float2(texel.x, 0.0)))
           + 0.075 * (lumaAt(input, s, uv + float2(4.0 * texel.x, 0.0))
                    - lumaAt(input, s, uv - float2(4.0 * texel.x, 0.0)));
  float gy = 0.50 * (lumaAt(input, s, uv + float2(0.0, texel.y))
                   - lumaAt(input, s, uv - float2(0.0, texel.y)))
           + 0.075 * (lumaAt(input, s, uv + float2(0.0, 4.0 * texel.y))
                    - lumaAt(input, s, uv - float2(0.0, 4.0 * texel.y)));
  float2 gradient = float2(gx, gy);
  float gradientEnergy = dot(gradient, gradient);
  float confidence = smoothstep(0.00002, 0.003, gradientEnergy);
  float2 displacement = -(fast - slow) * gradient
                      / max(gradientEnergy, 0.00002);
  float2 amplifiedPixels = clamp(
    displacement * p.gain * confidence,
    float2(-32.0), float2(32.0)
  );
  float2 sourceUV = uv - amplifiedPixels * texel;
  output.write(clamp(input.sample(s, sourceUV), 0.0, 1.0), gid);
}
