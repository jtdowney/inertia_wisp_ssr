import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

export default defineConfig(({ isSsrBuild }) => ({
  plugins: [svelte()],
  build: {
    manifest: true,
    outDir: isSsrBuild ? "priv/ssr" : "priv/static",
    rollupOptions: isSsrBuild
      ? {}
      : {
          input: "src/main.js",
          output: {
            entryFileNames: "[name]-[hash].js",
            chunkFileNames: "[name]-[hash].js",
            assetFileNames: "[name]-[hash][extname]",
          },
        },
  },
  ssr: {
    noExternal: ["@inertiajs/svelte"],
  },
}));
