import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Produce a self-contained server with minimal node_modules under .next/standalone
  output: "standalone",
};

export default nextConfig;
