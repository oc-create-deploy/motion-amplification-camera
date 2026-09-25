#include <metal_stdlib>
using namespace metal;

struct FilterUniforms { float dt, lowerHz, upperHz, gain; uint reset, luminanceOnly; };

// Eulerian temporal band-pass, evaluated per spatially-smoothed pixel:
// alpha(fc,dt) = 1 - exp(-2*pi*fc*dt)
// fast = fast + alpha(upper,dt)*(x-fast)
// slow = slow + alpha(lower,dt)*(x-slow)
// band = fast - slow; output = clamp(input + gain*band)
// Coefficients depend on camera timestamps, never frame counts.
kernel void amplifyLuma(texture2d<float, access::read> input [[texture(0)]],
                        texture2d<float, access::read_write> fastState [[texture(1)]],
                        texture2d<float, access::read_write> slowState [[texture(2)]],
                        texture2d<float, access::write> output [[texture(3)]],
                        constant FilterUniforms &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
  const uint2 maxCoord = uint2(input.get_width() - 1, input.get_height() - 1);
  float4 original = input.read(gid);
  // Five-tap base level of a Laplacian-style spatial pyramid. This suppresses
  // sensor noise before temporal processing without returning pixels to CPU.
  float4 spatial = original * 0.5;
  spatial += input.read(uint2(uint(max(int(gid.x)-1, 0)), gid.y)) * 0.125;
  spatial += input.read(uint2(min(gid.x+1, maxCoord.x), gid.y)) * 0.125;
  spatial += input.read(uint2(gid.x, uint(max(int(gid.y)-1, 0)))) * 0.125;
  spatial += input.read(uint2(gid.x, min(gid.y+1, maxCoord.y))) * 0.125;
  float luma = dot(spatial.rgb, float3(0.2126, 0.7152, 0.0722));
  float4 x = p.luminanceOnly != 0 ? float4(luma, luma, luma, original.a) : spatial;
  float4 fast = p.reset != 0 ? x : fastState.read(gid);
  float4 slow = p.reset != 0 ? x : slowState.read(gid);
  if (p.reset == 0 && p.dt > 0) {
    float fastAlpha = 1.0 - exp(-2.0 * M_PI_F * p.upperHz * p.dt);
    float slowAlpha = 1.0 - exp(-2.0 * M_PI_F * p.lowerHz * p.dt);
    fast += fastAlpha * (x - fast); slow += slowAlpha * (x - slow);
  }
  fastState.write(fast, gid); slowState.write(slow, gid);
  float4 amplified = original + p.gain * (fast - slow);
  output.write(clamp(amplified, 0.0, 1.0), gid);
}
