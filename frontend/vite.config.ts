import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { nodePolyfills } from "vite-plugin-node-polyfills";

// nodePolyfills: @inco/lightning-js pulls in Buffer/crypto in the browser.
// fs/promises has no browser equivalent — stub it to an empty module.
export default defineConfig({
  plugins: [react(), nodePolyfills({ globals: { Buffer: true } })],
  resolve: {
    alias: {
      "fs/promises": "node-stdlib-browser/mock/empty",
      "node:fs/promises": "node-stdlib-browser/mock/empty",
    },
  },
});
