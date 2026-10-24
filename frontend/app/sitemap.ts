import type { MetadataRoute } from "next";
import { NAV_LINKS, SITE } from "@/lib/site";

export default function sitemap(): MetadataRoute.Sitemap {
  return NAV_LINKS.map((l) => ({
    url: `${SITE.url}${l.href === "/" ? "" : l.href}`,
    changeFrequency: "weekly",
    priority: l.href === "/" ? 1 : 0.7,
  }));
}
