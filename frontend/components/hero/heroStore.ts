import { fillFraction } from "@/lib/xyc";

/// One plain mutable store shared by the scroll timeline (writes) and the WebGL render loop and
/// HUD (read every frame). A single scrubbed GSAP timeline tweens it; nothing re-renders React.
export const heroStore = {
  live: 1000, // real ExposureOracle reading, bps
  scripted: 1000, // the story's simulated reading, bps
  weight: 0, // 0 = show live reading, 1 = show scripted reading
  cam: 0, // camera keyframe position, 0..3
  side: 1, // where the 3D subject sits on wide screens: 1 = right of the copy, -1 = left of it
  maxBps: 5000,
  haltBps: 9000,
};

export function storeExposure(): number {
  return heroStore.live + (heroStore.scripted - heroStore.live) * heroStore.weight;
}

export function storeFill(): number {
  return fillFraction(storeExposure(), heroStore.maxBps, heroStore.haltBps);
}
