#ifdef GL_ES
precision mediump float;
#endif

// Phong related variables
uniform sampler2D uSampler;
uniform vec3 uKd;
uniform vec3 uKs;
uniform vec3 uLightPos;
uniform vec3 uCameraPos;
uniform vec3 uLightIntensity;

varying highp vec2 vTextureCoord;
varying highp vec3 vFragPos;
varying highp vec3 vNormal;

// Shadow map related variables
#define NUM_SAMPLES 24
#define BLOCKER_SEARCH_NUM_SAMPLES 24
#define PCF_NUM_SAMPLES NUM_SAMPLES
#define NUM_RINGS 10

#define Z_NEAR 0.1
#define LIGHT_WORLD_SIZE 30.0
#define LIGHT_FRUSTUM_WIDTH 512.0
#define LIGHT_SIZE_UV (LIGHT_WORLD_SIZE / LIGHT_FRUSTUM_WIDTH)

#define EPS 1e-3
#define PI 3.141592653589793
#define PI2 6.283185307179586

uniform sampler2D uShadowMap;

varying vec4 vPositionFromLight;

highp float rand_1to1(highp float x ) { 
  // -1 -1
  return fract(sin(x)*10000.0);
}

highp float rand_2to1(vec2 uv ) { 
  // 0 - 1
	const highp float a = 12.9898, b = 78.233, c = 43758.5453;
	highp float dt = dot( uv.xy, vec2( a,b ) ), sn = mod( dt, PI );
	return fract(sin(sn) * c);
}

float unpack(vec4 rgbaDepth) {
    const vec4 bitShift = vec4(1.0, 1.0/256.0, 1.0/(256.0*256.0), 1.0/(256.0*256.0*256.0));
    return dot(rgbaDepth, bitShift);
}

vec2 poissonDisk[NUM_SAMPLES];

void poissonDiskSamples( const in vec2 randomSeed ) {

  float ANGLE_STEP = PI2 * float( NUM_RINGS ) / float( NUM_SAMPLES );
  float INV_NUM_SAMPLES = 1.0 / float( NUM_SAMPLES );

  float angle = rand_2to1( randomSeed ) * PI2;
  float radius = INV_NUM_SAMPLES;
  float radiusStep = radius;

  for( int i = 0; i < NUM_SAMPLES; i ++ ) {
    poissonDisk[i] = vec2( cos( angle ), sin( angle ) ) * pow( radius, 0.75 );
    radius += radiusStep;
    angle += ANGLE_STEP;
  }
}

void uniformDiskSamples( const in vec2 randomSeed ) {

  float randNum = rand_2to1(randomSeed);
  float sampleX = rand_1to1( randNum ) ;
  float sampleY = rand_1to1( sampleX ) ;

  float angle = sampleX * PI2;
  float radius = sqrt(sampleY);

  for( int i = 0; i < NUM_SAMPLES; i ++ ) {
    poissonDisk[i] = vec2( radius * cos(angle) , radius * sin(angle)  );

    sampleX = rand_1to1( sampleY ) ;
    sampleY = rand_1to1( sampleX ) ;

    angle = sampleX * PI2;
    radius = sqrt(sampleY);
  }
}

float useShadowMap(sampler2D shadowMap, vec4 shadowCoord) {
  // use ortho projection
  // coord: [-1, 1] -> [0, 1]
  float nearest = unpack(texture2D(shadowMap, vec2(shadowCoord.x * 0.5 + 0.5, shadowCoord.y * 0.5 + 0.5)).rgba);
  float current = shadowCoord.z * 0.5 + 0.5;
  return current - nearest > 0.001 ? 0.0 : 1.0;
}

float poissonPCF(sampler2D shadowMap, vec4 coords) {
  // uniformDiskSamples(coords.xy);
  poissonDiskSamples(vec2(3541.3, 1209.6));
  
  float visibility = 0.0;
  float scale = 4.0 / 2048.0;

  float current = coords.z * 0.5 + 0.5;

  for (int i = 0; i < NUM_SAMPLES; i++)
  {
    vec2 coord_base = vec2(coords.x * 0.5 + 0.5, coords.y * 0.5 + 0.5);
    float nearest = unpack(texture2D(shadowMap, coord_base + poissonDisk[i] * scale).rgba);
    visibility += current - nearest > 0.005 ? 0.0 : 1.0;
  }
  return visibility / float(NUM_SAMPLES);
}


// 固定seed，scale 4.0/2048, bias 0.003 看起来还可以
float uniformPCF(sampler2D shadowMap, vec4 coords) {
  // uniformDiskSamples(coords.xy * 100.0); // 噪点会很多？
  uniformDiskSamples(vec2(3541.3, 1209.6));
  
  float visibility = 0.0;
  float scale = 4.0 / 2048.0;

  float current = coords.z * 0.5 + 0.5;

  for (int i = 0; i < NUM_SAMPLES; i++)
  {
    vec2 coord_base = vec2(coords.x * 0.5 + 0.5, coords.y * 0.5 + 0.5);
    float nearest = unpack(texture2D(shadowMap, coord_base + poissonDisk[i] * scale).rgba);
    visibility += current - nearest > 0.003 ? 0.0 : 1.0;
  }
  return visibility / float(NUM_SAMPLES);
}
/**
* 目的是糊掉原有的形状（由于shadowMap分辨率限制形成的锯齿
* 而 block sample 因其采样的方向性倾向于保留原有形状
* 形成的效果只是相同形状的锯齿往外越来越淡
*/
float blockPCF(sampler2D shadowMap, vec4 coords) {
  uniformDiskSamples(vec2(3541.3, 1209.6));
  
  float visibility = 0.0;
  float scale = 1.0 / 2048.0;

  float current = coords.z * 0.5 + 0.5;

  for (int i = -6 / 2; i < 6 / 2; i++)
  {
    vec2 coord_base = vec2(coords.x * 0.5 + 0.5, coords.y * 0.5 + 0.5);
    float nearest = unpack(texture2D(shadowMap, coord_base + vec2(i, i) * scale).rgba);
    visibility += current - nearest > 0.001 ? 0.0 : 1.0;
  }
  return visibility / 6.0;
}

float poissonPCF(sampler2D shadowMap, vec2 uv, float zReceiver, float filterRadiusUV)
{
  // poissonDiskSamples(uv);
  // poissonDiskSamples(vec2(3541.3, 1209.6));
  
  float visibility = 0.0;

  for (int i = 0; i < NUM_SAMPLES; i++)
  {
    float nearest = unpack(texture2D(shadowMap, uv + poissonDisk[i] * filterRadiusUV).rgba);
    visibility += zReceiver - nearest > 0.003 ? 0.0 : 1.0;
  }
  return visibility / float(NUM_SAMPLES);
}

float findBlocker(sampler2D shadowMap,  vec2 uv, float zReceiver ) {
  float search_width = 0.8 * LIGHT_SIZE_UV * (zReceiver - Z_NEAR) / zReceiver; // 不能太大 不然影子没了
  
  float block_depth_sum = 0.0;
  float block_num = 0.0;

  for (int i = 0; i < BLOCKER_SEARCH_NUM_SAMPLES; i++)
  {
    float shadow_map_depth = unpack(texture2D(shadowMap, uv + poissonDisk[i] * search_width).rgba);
    if (zReceiver - shadow_map_depth > 0.003)
    {
      block_depth_sum += shadow_map_depth;
      block_num++;
    }
  }
  // if (block_num == float(BLOCKER_SEARCH_NUM_SAMPLES))
  //   return 1.1;
  if (block_num == 0.0)
    return 0.0;
	return block_depth_sum / block_num;
}

float PCSS(sampler2D shadowMap, vec4 coords){
  // STEP 1: avgblocker depth
  float z_receiver = coords.z * 0.5 + 0.5;
  vec2 coords_base = coords.xy * 0.5 + 0.5;
  // do sample once, for block search and pcf
  poissonDiskSamples(coords_base);
  // poissonDiskSamples(vec2(123, 187));

  float z_blocker = findBlocker(shadowMap, coords_base, z_receiver);
  
  if (z_blocker < 0.0001)
    return 1.0;
  
  // if (z_blocker > 1.0)
  //   return 0.0;

  // STEP 2: penumbra size
  float penumbra_ratio = (z_receiver - z_blocker) / z_blocker;
  float filter_radius_uv = 1.0 * penumbra_ratio * LIGHT_SIZE_UV * Z_NEAR / z_receiver;
  
  // STEP 3: filtering
  return poissonPCF(shadowMap, coords_base, z_receiver, filter_radius_uv);
  // return filter_radius_uv;
  // return z_blocker;
}
float test(sampler2D shadowMap, vec2 uv, float z, float scale)
{
  return poissonPCF(shadowMap, uv, z, scale); 
}

vec3 blinnPhong() {
  vec3 color = texture2D(uSampler, vTextureCoord).rgb;
  color = pow(color, vec3(2.2));

  vec3 ambient = 0.05 * color;

  vec3 lightDir = normalize(uLightPos);
  vec3 normal = normalize(vNormal);
  float diff = max(dot(lightDir, normal), 0.0);
  vec3 light_atten_coff =
      uLightIntensity / pow(length(uLightPos - vFragPos), 2.0);
  vec3 diffuse = diff * light_atten_coff * color;

  vec3 viewDir = normalize(uCameraPos - vFragPos);
  vec3 halfDir = normalize((lightDir + viewDir));
  float spec = pow(max(dot(halfDir, normal), 0.0), 32.0);
  vec3 specular = uKs * light_atten_coff * spec;

  vec3 radiance = (ambient + diffuse + specular);
  vec3 phongColor = pow(radiance, vec3(1.0 / 2.2));
  return phongColor;
}

void main(void) {

  float visibility;
  // visibility = useShadowMap(uShadowMap, vPositionFromLight);
  // visibility = blockPCF(uShadowMap, vPositionFromLight);
  // visibility = uniformPCF(uShadowMap, vPositionFromLight);
  // visibility = poissonPCF(uShadowMap, vPositionFromLight);

  // vec2 uv = vPositionFromLight.xy * 0.5 + 0.5;
  // float z_receiver = vPositionFromLight.z * 0.5 + 0.5;
  //   visibility = poissonPCF(uShadowMap, uv, z_receiver, 4.0 / 2048.0);
  visibility = PCSS(uShadowMap, vPositionFromLight);
  // visibility = test(uShadowMap, uv, z_receiver, 4.0 / 2048.0);
  // visibility = 4.0 / 256.0;
  vec3 phongColor = blinnPhong();

  gl_FragColor = vec4(phongColor * visibility, 1.0);

  // gl_FragColor = vec4(visibility, visibility, visibility, 1.0);

  // gl_FragColor = vec4(phongColor, 1.0);
}