import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ isSsrBuild }) => ({
  plugins: [react()],
  build: {
    manifest: true,
    outDir: isSsrBuild ? "priv/ssr" : "priv/static",
    rollupOptions: isSsrBuild
      ? {}
      : {
          input: "src/main.jsx",
          output: {
            entryFileNames: "[name]-[hash].js",
            chunkFileNames: "[name]-[hash].js",
            assetFileNames: "[name]-[hash][extname]",
          },
        },
  },
  ssr: {
    noExternal: ["@inertiajs/react"],
  },
}));
