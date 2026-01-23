import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

export default defineConfig(({ isSsrBuild }) => ({
  plugins: [vue()],
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
    noExternal: false,
  },
}));
