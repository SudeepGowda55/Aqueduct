"use client";

/* eslint-disable react-hooks/immutability, react-hooks/purity --
   R3F idiom: three.js materials/geometries are created once and mutated inside useFrame (the
   render loop, outside React render), and particle seeds are random by design. */

import { Canvas, useFrame, useThree } from "@react-three/fiber";
import { useEffect, useMemo, useRef } from "react";
import * as THREE from "three";
import { heroStore, storeFill } from "./heroStore";

/*
 * The aqueduct, in 3D. Same metaphor as the SVG scene: the channel carries the maker's Aqua
 * liquidity, the sluice gate is `_exposureGate1D`, and the two outlets are SwapVM and Uniswap v4.
 * The gate's only travel is DOWN into the channel -- there is no position above the rim.
 * Everything animated reads `heroStore` each frame and eases toward it.
 */

const X0 = -16; // upstream end
const X1 = 10; // channel mouth
const GATE_X = -2;
const LOWER_H = 5.2;
const CORNICE = 0.28;
const UPPER_H = 1.9;
const BED = LOWER_H + CORNICE + UPPER_H; // top of the upper arcade
const BED_TOP = BED + 0.3;
const DEPTH = 0.78; // full water depth
const INNER = 1.3; // channel inner width (z)
const TIER_Z = 1.8;
const SURFACE_LIFT = 0.045; // > the vertex wave amplitude, so the surface never dips into the body (z-fighting)

const C = {
  stone: "#e6d7b9",
  stoneDark: "#cdb894",
  plate: "#2a251f",
  deep: new THREE.Color("#0f5f66"),
  shallow: new THREE.Color("#54c3c3"),
  safe: "#1f8659",
  derate: "#c08a10",
  halt: "#a8302a",
};

/// MeshStandardMaterial + procedural masonry computed from world position (no textures, no
/// UV stretching on long boxes): staggered block courses, mortar lines, per-block tone, and a
/// little weathering toward the ground.
function stoneMaterial(color: string, block = 1.1, course = 0.55) {
  const m = new THREE.MeshStandardMaterial({ color, roughness: 0.93 });
  m.onBeforeCompile = (shader) => {
    shader.vertexShader = shader.vertexShader
      .replace("#include <common>", "#include <common>\nvarying vec3 vWPos;\nvarying vec3 vWNormal;")
      .replace(
        "#include <begin_vertex>",
        "#include <begin_vertex>\nvWPos = (modelMatrix * vec4(transformed, 1.0)).xyz;\nvWNormal = normalize(mat3(modelMatrix) * objectNormal);"
      );
    shader.fragmentShader = shader.fragmentShader
      .replace("#include <common>", "#include <common>\nvarying vec3 vWPos;\nvarying vec3 vWNormal;")
      .replace(
        "#include <color_fragment>",
        `#include <color_fragment>
        vec3 an = abs(vWNormal);
        vec2 sp = an.y > 0.6 ? vWPos.xz : (an.x > an.z ? vWPos.zy : vWPos.xy);
        float row = floor(sp.y / ${course.toFixed(3)});
        float off = mod(row, 2.0) * 0.5;
        vec2 cell = vec2(sp.x / ${block.toFixed(3)} + off, sp.y / ${course.toFixed(3)});
        vec2 fc = fract(cell);
        float mortar = clamp(step(fc.y, 0.05) + step(fc.x, 0.028), 0.0, 1.0);
        float h = fract(sin(dot(floor(cell), vec2(12.9898, 78.233))) * 43758.5453);
        diffuseColor.rgb *= 0.88 + 0.16 * h;
        diffuseColor.rgb = mix(diffuseColor.rgb, diffuseColor.rgb * 0.7, mortar * 0.75);
        diffuseColor.rgb *= mix(0.84, 1.0, smoothstep(0.0, 3.5, vWPos.y));`
      );
  };
  return m;
}

function arcadeShape(length: number, height: number, bays: number, archW: number, springY: number) {
  // One outline with the arches cut up from the base: no holes touching edges to triangulate.
  const s = new THREE.Shape();
  s.moveTo(0, 0);
  const bay = length / bays;
  const r = archW / 2;
  for (let i = 0; i < bays; i++) {
    const a = i * bay + (bay - archW) / 2;
    s.lineTo(a, 0);
    s.lineTo(a, springY);
    s.absarc(a + r, springY, r, Math.PI, 0, true);
    s.lineTo(a + archW, 0);
  }
  s.lineTo(length, 0);
  s.lineTo(length, height);
  s.lineTo(0, height);
  s.closePath();
  return s;
}

function useArcade(length: number, height: number, bays: number, archW: number, springY: number, depth: number) {
  return useMemo(() => {
    const g = new THREE.ExtrudeGeometry(arcadeShape(length, height, bays, archW, springY), {
      depth,
      bevelEnabled: false,
      curveSegments: 20,
    });
    g.translate(0, 0, -depth / 2);
    return g;
  }, [length, height, bays, archW, springY, depth]);
}

const waterVert = /* glsl */ `
  uniform float uTime;
  varying vec2 vUv;
  void main() {
    vUv = uv;
    vec3 p = position;
    p.z += sin(p.x * 2.2 + uTime * 2.6) * 0.025 + sin(p.y * 6.0 - uTime * 1.9) * 0.012;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
  }
`;
const waterFrag = /* glsl */ `
  uniform float uTime;
  uniform float uSpeed;
  uniform float uLen;
  uniform vec3 uDeep;
  uniform vec3 uShallow;
  varying vec2 vUv;
  float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
  }
  void main() {
    // Stretched along the flow so it reads as current, not blotches.
    vec2 q = vec2(vUv.x * uLen * 1.6 - uTime * uSpeed * 1.8, vUv.y * 5.0);
    float n = noise(q * vec2(0.9, 1.6)) * 0.55 + noise(q * vec2(2.4, 4.2) + 4.0) * 0.3 + noise(q * vec2(6.0, 9.0) - uTime) * 0.15;
    float streak = smoothstep(0.62, 0.9, n);
    vec3 col = mix(uDeep, uShallow, 0.45 + 0.3 * n);
    col += streak * 0.22;
    float edge = smoothstep(0.0, 0.18, vUv.y) * smoothstep(1.0, 0.82, vUv.y);
    col = mix(col * 0.82, col, edge);
    gl_FragColor = vec4(col, 0.96);
  }
`;
const streamFrag = /* glsl */ `
  uniform float uTime;
  uniform vec3 uDeep;
  uniform vec3 uShallow;
  varying vec2 vUv;
  void main() {
    float s = fract(vUv.x * 9.0 - uTime * 1.8);
    float stripe = smoothstep(0.0, 0.25, s) * smoothstep(0.7, 0.35, s);
    vec3 col = mix(uDeep, uShallow, 0.55 + 0.25 * sin(vUv.y * 6.2831));
    col += stripe * 0.28;
    gl_FragColor = vec4(col, 0.94);
  }
`;
const plainVert = /* glsl */ `
  varying vec2 vUv;
  void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }
`;

function useWaterMaterial(len: number, speed: number) {
  return useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: waterVert,
        fragmentShader: waterFrag,
        transparent: true,
        uniforms: {
          uTime: { value: 0 },
          uSpeed: { value: speed },
          uLen: { value: len },
          uDeep: { value: C.deep },
          uShallow: { value: C.shallow },
        },
      }),
    [len, speed]
  );
}

const STREAM_CURVES = [1, -1].map(
  (side) =>
    new THREE.CatmullRomCurve3([
      new THREE.Vector3(X1 - 0.1, BED_TOP + DEPTH * 0.6, side * 0.3),
      new THREE.Vector3(X1 + 0.9, BED_TOP + 0.1, side * 0.9),
      new THREE.Vector3(X1 + 2.1, BED * 0.55, side * 2.0),
      new THREE.Vector3(X1 + 2.5, 1.0, side * 2.5),
    ])
);
const BASIN_POS = [1, -1].map((side) => new THREE.Vector3(X1 + 2.5, 0.45, side * 2.5));

// Tube radius tracks the fill; geometries are cached per 5% step instead of rebuilt per frame.
const tubeCache = new Map<string, THREE.TubeGeometry>();
function tube(i: number, step: number) {
  const key = `${i}:${step}`;
  let g = tubeCache.get(key);
  if (!g) {
    g = new THREE.TubeGeometry(STREAM_CURVES[i], 64, 0.04 + 0.24 * (step / 20), 12, false);
    tubeCache.set(key, g);
  }
  return g;
}

const CAM_KEYS = [
  { p: new THREE.Vector3(-26, 19, 34), t: new THREE.Vector3(-3, 5.4, 0) }, // wide establishing shot
  { p: new THREE.Vector3(-13, 17, 12.5), t: new THREE.Vector3(-0.5, 7.8, 0) }, // above the gate, upstream
  { p: new THREE.Vector3(7.5, 14.5, 10.5), t: new THREE.Vector3(-3, 8, 0) }, // downstream, looking back at the gate
  { p: new THREE.Vector3(19, 18, 12), t: new THREE.Vector3(1.5, 6.8, 0) }, // dry channel, gate and outlets
];

function Rig() {
  const { camera, size, pointer, scene } = useThree();
  const pos = useRef(CAM_KEYS[0].p.clone());
  const look = useRef(CAM_KEYS[0].t.clone());
  const tp = useMemo(() => new THREE.Vector3(), []);
  const tt = useMemo(() => new THREE.Vector3(), []);

  useEffect(() => {
    const cam = camera as THREE.PerspectiveCamera;
    // Keep the subject clear of the text: push it right on desktop, up on phones.
    if (size.width >= 1024) cam.setViewOffset(size.width, size.height, -size.width * 0.21, 0, size.width, size.height);
    else cam.setViewOffset(size.width, size.height, 0, -size.height * 0.22, size.width, size.height);
    cam.updateProjectionMatrix();
  }, [camera, size]);

  useFrame(() => {
    const c = Math.max(0, Math.min(CAM_KEYS.length - 1, heroStore.cam));
    const i = Math.min(CAM_KEYS.length - 2, Math.floor(c));
    const f = c - i;
    const e = f * f * (3 - 2 * f);
    tp.lerpVectors(CAM_KEYS[i].p, CAM_KEYS[i + 1].p, e);
    tt.lerpVectors(CAM_KEYS[i].t, CAM_KEYS[i + 1].t, e);
    // Portrait screens: pull back so the whole structure fits.
    const aspect = size.width / size.height;
    const pull = aspect < 1 ? 1 + (1 - aspect) * 1.3 : 1;
    tp.sub(tt).multiplyScalar(pull).add(tt);
    // Fog distance follows the pull-back so portrait screens don't see a washed-out structure.
    if (scene.fog instanceof THREE.Fog) {
      scene.fog.near = 34 * pull;
      scene.fog.far = 80 * pull;
    }
    tp.x += pointer.x * 1.2;
    tp.y += pointer.y * 0.6;
    pos.current.lerp(tp, 0.06);
    look.current.lerp(tt, 0.06);
    camera.position.copy(pos.current);
    camera.lookAt(look.current);
  });
  return null;
}

function Structure() {
  const lower = useArcade(X1 - X0, LOWER_H, 6, 2.9, 2.75, TIER_Z);
  const upper = useArcade(X1 - X0, UPPER_H, 13, 1.15, 0.85, TIER_Z * 0.92);
  const stone = useMemo(() => stoneMaterial(C.stone), []);
  const stoneDark = useMemo(() => stoneMaterial(C.stoneDark, 0.9, 0.3), []);
  const L = X1 - X0;
  return (
    <group>
      <mesh geometry={lower} material={stone} position={[X0, 0, 0]} castShadow receiveShadow />
      <mesh material={stoneDark} position={[X0 + L / 2, LOWER_H + CORNICE / 2, 0]} castShadow receiveShadow>
        <boxGeometry args={[L + 0.3, CORNICE, TIER_Z + 0.3]} />
      </mesh>
      <mesh geometry={upper} material={stone} position={[X0, LOWER_H + CORNICE, 0]} castShadow receiveShadow />
      {/* channel bed + walls */}
      <mesh material={stoneDark} position={[X0 + L / 2, BED + 0.15, 0]} castShadow receiveShadow>
        <boxGeometry args={[L, 0.3, TIER_Z + 0.2]} />
      </mesh>
      {[1, -1].map((s) => (
        <mesh key={s} material={stone} position={[X0 + L / 2, BED_TOP + 0.45, s * (INNER / 2 + 0.13)]} castShadow receiveShadow>
          <boxGeometry args={[L, 0.9, 0.26]} />
        </mesh>
      ))}
      {BASIN_POS.map((b, i) => (
        <mesh key={i} material={stoneDark} position={[b.x, b.y, b.z]} castShadow receiveShadow>
          <boxGeometry args={[1.9, 0.9, 1.7]} />
        </mesh>
      ))}
    </group>
  );
}

function Water() {
  const upLen = GATE_X - 0.12 - X0;
  const downLen = X1 - (GATE_X + 0.12);
  const upMat = useWaterMaterial(upLen / 2, 0.9);
  const downMat = useWaterMaterial(downLen / 2, 0.9);
  const streamMats = useMemo(
    () =>
      [0, 1].map(
        () =>
          new THREE.ShaderMaterial({
            vertexShader: plainVert,
            fragmentShader: streamFrag,
            transparent: true,
            uniforms: { uTime: { value: 0 }, uDeep: { value: C.deep }, uShallow: { value: C.shallow } },
          })
      ),
    []
  );
  const bodyMat = useMemo(() => new THREE.MeshStandardMaterial({ color: "#1f8f95", roughness: 0.25, transparent: true, opacity: 0.88 }), []);
  const downBody = useRef<THREE.Mesh>(null);
  const downTop = useRef<THREE.Mesh>(null);
  const streams = useRef<(THREE.Mesh | null)[]>([]);
  const basins = useRef<(THREE.Mesh | null)[]>([]);
  const fillRef = useRef(1);

  useFrame((state, dt) => {
    const t = state.clock.elapsedTime;
    fillRef.current += (storeFill() - fillRef.current) * Math.min(1, dt * 3);
    const f = fillRef.current;
    upMat.uniforms.uTime.value = t;
    downMat.uniforms.uTime.value = t;
    downMat.uniforms.uSpeed.value = 0.25 + 0.9 * f;
    streamMats.forEach((m) => (m.uniforms.uTime.value = t));

    const h = Math.max(0.001, DEPTH * f);
    if (downBody.current) {
      downBody.current.scale.y = h;
      downBody.current.position.y = BED_TOP + h / 2;
      downBody.current.visible = f > 0.01;
    }
    if (downTop.current) {
      downTop.current.position.y = BED_TOP + h + SURFACE_LIFT;
      downTop.current.visible = f > 0.01;
    }
    const step = Math.round(f * 20);
    streams.current.forEach((m, i) => {
      if (!m) return;
      m.visible = step > 0;
      if (step > 0 && m.userData.step !== step) {
        m.geometry = tube(i, step);
        m.userData.step = step;
      }
    });
    basins.current.forEach((m) => {
      if (!m) return;
      const bh = Math.max(0.001, 0.6 * f);
      m.scale.y = bh;
      m.position.y = 0.12 + bh / 2;
    });
  });

  const L1 = upLen;
  const L2 = downLen;
  return (
    <group>
      {/* upstream: always full, it's the maker's committed liquidity */}
      <mesh material={bodyMat} position={[X0 + L1 / 2, BED_TOP + DEPTH / 2, 0]}>
        <boxGeometry args={[L1, DEPTH, INNER]} />
      </mesh>
      <mesh material={upMat} rotation-x={-Math.PI / 2} position={[X0 + L1 / 2, BED_TOP + DEPTH + SURFACE_LIFT, 0]}>
        <planeGeometry args={[L1, INNER, 160, 8]} />
      </mesh>
      {/* downstream: scaled by the gate */}
      <mesh ref={downBody} material={bodyMat} position={[GATE_X + 0.12 + L2 / 2, BED_TOP + DEPTH / 2, 0]}>
        <boxGeometry args={[L2, 1, INNER]} />
      </mesh>
      <mesh ref={downTop} material={downMat} rotation-x={-Math.PI / 2} position={[GATE_X + 0.12 + L2 / 2, BED_TOP + DEPTH, 0]}>
        <planeGeometry args={[L2, INNER, 120, 8]} />
      </mesh>
      {[0, 1].map((i) => (
        <mesh key={i} ref={(m) => void (streams.current[i] = m)} material={streamMats[i]} geometry={tube(i, 20)} />
      ))}
      {BASIN_POS.map((b, i) => (
        <mesh key={i} ref={(m) => void (basins.current[i] = m)} material={bodyMat} position={[b.x, 0.4, b.z]}>
          <boxGeometry args={[1.6, 1, 1.4]} />
        </mesh>
      ))}
      <Spray />
    </group>
  );
}

const SPRAY_N = 260;
function Spray() {
  const geo = useMemo(() => {
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.BufferAttribute(new Float32Array(SPRAY_N * 3), 3));
    return g;
  }, []);
  const vel = useMemo(() => new Float32Array(SPRAY_N * 3), []);
  const life = useMemo(() => Float32Array.from({ length: SPRAY_N }, () => Math.random()), []);

  useFrame((_, dt) => {
    const f = storeFill();
    const pos = geo.attributes.position as THREE.BufferAttribute;
    const arr = pos.array as Float32Array;
    const active = Math.floor(SPRAY_N * f);
    for (let i = 0; i < SPRAY_N; i++) {
      life[i] -= dt * 1.4;
      if (life[i] <= 0) {
        life[i] = 0.6 + Math.random() * 0.6;
        const b = BASIN_POS[i % 2];
        arr[i * 3] = b.x + (Math.random() - 0.5) * 0.5;
        arr[i * 3 + 1] = 1.0;
        arr[i * 3 + 2] = b.z + (Math.random() - 0.5) * 0.5;
        vel[i * 3] = (Math.random() - 0.5) * 1.6;
        vel[i * 3 + 1] = 1.2 + Math.random() * 1.8;
        vel[i * 3 + 2] = (Math.random() - 0.5) * 1.6;
      }
      vel[i * 3 + 1] -= 6 * dt;
      arr[i * 3] += vel[i * 3] * dt;
      arr[i * 3 + 1] = Math.max(0.5, arr[i * 3 + 1] + vel[i * 3 + 1] * dt);
      arr[i * 3 + 2] += vel[i * 3 + 2] * dt;
    }
    pos.needsUpdate = true;
    geo.setDrawRange(0, active);
  });

  return (
    <points geometry={geo}>
      <pointsMaterial color="#cdeeee" size={0.09} transparent opacity={0.85} depthWrite={false} />
    </points>
  );
}

function Gate() {
  const gl = useThree((s) => s.gl);
  const frames = useRef(0);
  const plate = useRef<THREE.Mesh>(null);
  const rod = useRef<THREE.Mesh>(null);
  const wheel = useRef<THREE.Group>(null);
  const strip = useMemo(() => new THREE.MeshStandardMaterial({ color: C.safe, emissive: C.safe, emissiveIntensity: 0.6 }), []);
  const f = useRef(1);
  const colors = useMemo(() => ({ safe: new THREE.Color(C.safe), derate: new THREE.Color(C.derate), halt: new THREE.Color(C.halt) }), []);
  const PLATE_H = 1.7;
  const TOP = BED_TOP + 2.9;

  useFrame((_, dt) => {
    // Heavy gate: eases a little slower than the water so it visibly "pushes" the level.
    const prev = f.current;
    f.current += (storeFill() - f.current) * Math.min(1, dt * 2.2);
    // Everything else that casts a shadow is static stone: re-render the shadow map only while the
    // gate is moving (plus the first few frames while the scene settles).
    if (Math.abs(f.current - prev) > 1e-4 || frames.current++ < 4) gl.shadowMap.needsUpdate = true;
    const bottom = BED_TOP + (DEPTH + 0.06) * f.current;
    if (plate.current) plate.current.position.y = bottom + PLATE_H / 2;
    if (rod.current) {
      const len = TOP - (bottom + PLATE_H);
      rod.current.scale.y = Math.max(0.01, len);
      rod.current.position.y = bottom + PLATE_H + len / 2;
    }
    if (wheel.current) wheel.current.rotation.z = (1 - f.current) * Math.PI * 3;
    const target = f.current <= 0.01 ? colors.halt : f.current < 0.999 ? colors.derate : colors.safe;
    strip.color.lerp(target, 0.1);
    strip.emissive.lerp(target, 0.1);
  });

  return (
    <group position={[GATE_X, 0, 0]}>
      {[1, -1].map((s) => (
        <mesh key={s} position={[0, BED_TOP + 1.5, s * (INNER / 2 + 0.42)]} castShadow>
          <boxGeometry args={[0.32, 3.0, 0.3]} />
          <meshStandardMaterial color="#a8946f" roughness={0.9} />
        </mesh>
      ))}
      <mesh position={[0, TOP + 0.1, 0]} castShadow>
        <boxGeometry args={[0.5, 0.3, INNER + 1.3]} />
        <meshStandardMaterial color={C.plate} roughness={0.6} />
      </mesh>
      <group ref={wheel} position={[0, TOP + 0.85, 0]}>
        <mesh castShadow>
          <torusGeometry args={[0.5, 0.06, 10, 40]} />
          <meshStandardMaterial color={C.plate} metalness={0.4} roughness={0.5} />
        </mesh>
        {[0, 1, 2].map((k) => (
          <mesh key={k} rotation-z={(k * Math.PI) / 3}>
            <boxGeometry args={[1.0, 0.06, 0.06]} />
            <meshStandardMaterial color={C.plate} />
          </mesh>
        ))}
      </group>
      <mesh ref={rod} position={[0, TOP, 0]}>
        <boxGeometry args={[0.1, 1, 0.1]} />
        <meshStandardMaterial color="#6c6252" metalness={0.5} roughness={0.4} />
      </mesh>
      <mesh ref={plate} castShadow>
        <boxGeometry args={[0.2, PLATE_H, INNER + 0.06]} />
        <meshStandardMaterial color={C.plate} metalness={0.35} roughness={0.55} />
        {/* band-colored seal along the plate's bottom edge */}
        {[0.11, -0.11].map((x) => (
          <mesh key={x} position={[x, -PLATE_H / 2 + 0.06, 0]} material={strip}>
            <boxGeometry args={[0.02, 0.12, INNER + 0.06]} />
          </mesh>
        ))}
      </mesh>
    </group>
  );
}

/// Steps the render resolution down (never back up, to avoid oscillating) while frames stay slow,
/// so weaker GPUs keep the water moving smoothly instead of dropping frames.
function AdaptiveDpr() {
  const setDpr = useThree((s) => s.setDpr);
  const dpr = useThree((s) => s.viewport.dpr);
  const acc = useRef({ t: 0, n: 0 });
  useFrame((_, dt) => {
    const a = acc.current;
    a.t += dt;
    a.n += 1;
    if (a.t < 1.5) return;
    const avg = a.t / a.n;
    a.t = 0;
    a.n = 0;
    if (avg > 1 / 45 && dpr > 1) setDpr(Math.max(1, Math.round((dpr - 0.25) * 4) / 4));
  });
  return null;
}

/// Build every stream tube while the browser is idle, so a fill change never builds geometry mid-scroll.
function usePrebuildTubes() {
  useEffect(() => {
    const jobs: [number, number][] = [];
    for (let s = 1; s <= 20; s++) jobs.push([0, s], [1, s]);
    const ric = window.requestIdleCallback ?? ((cb: IdleRequestCallback) => window.setTimeout(() => cb({ timeRemaining: () => 8, didTimeout: false }), 50));
    let id = 0;
    const work: IdleRequestCallback = (deadline) => {
      while (jobs.length && deadline.timeRemaining() > 2) {
        const [i, s] = jobs.pop()!;
        tube(i, s);
      }
      if (jobs.length) id = ric(work);
    };
    id = ric(work);
    return () => (window.cancelIdleCallback ?? window.clearTimeout)(id);
  }, []);
}

function Lights() {
  return (
    <>
      <hemisphereLight args={["#fff7ea", "#b9a47e", 1.05]} />
      <directionalLight
        position={[-14, 20, 18]}
        intensity={2.8}
        color="#fff1dc"
        castShadow
        shadow-mapSize={[1024, 1024]}
        shadow-camera-left={-22}
        shadow-camera-right={22}
        shadow-camera-top={16}
        shadow-camera-bottom={-10}
        shadow-bias={-0.0004}
      />
      <mesh rotation-x={-Math.PI / 2} receiveShadow>
        <planeGeometry args={[160, 160]} />
        <shadowMaterial opacity={0.16} />
      </mesh>
    </>
  );
}

export default function AqueductCanvas({ active, onReady }: { active: boolean; onReady?: () => void }) {
  usePrebuildTubes();
  return (
    <Canvas
      shadows={{ type: THREE.PCFShadowMap }}
      dpr={[1, 1.5]}
      frameloop={active ? "always" : "never"}
      camera={{ fov: 32, near: 0.5, far: 120, position: [-17, 10, 24] }}
      gl={{ alpha: true, antialias: true, powerPreference: "high-performance" }}
      onCreated={({ scene, gl }) => {
        scene.fog = new THREE.Fog("#f3ede1", 34, 80);
        gl.shadowMap.autoUpdate = false;
        gl.shadowMap.needsUpdate = true;
        // Let the first frame (shader compile) land before fading the canvas in.
        requestAnimationFrame(() => requestAnimationFrame(() => onReady?.()));
      }}
      aria-label="3D aqueduct: liquidity flows through the exposure gate into the SwapVM and Uniswap v4 outlets"
      role="img"
    >
      <Lights />
      <AdaptiveDpr />
      <Rig />
      <Structure />
      <Water />
      <Gate />
    </Canvas>
  );
}
