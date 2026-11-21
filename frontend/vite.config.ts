/// <reference types="node" />
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  base: "./",
  plugins: [
    react(),
    {
      name: "local-webview-entry",
      transformIndexHtml: {
        order: "post",
        handler(html, context) {
          // One classic, deferred bundle works from WKWebView's local file origin.
          // Module scripts would require CORS even though every asset is local.
          return context.bundle
            ? html
                .replace(/<script type="module" crossorigin/g, "<script defer")
                .replace(
                  /<link rel="stylesheet" crossorigin/g,
                  '<link rel="stylesheet"',
                )
            : html;
        },
      },
    },
  ],
  build: {
    target: "safari17",
    modulePreload: false,
    cssCodeSplit: false,
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 600,
    rolldownOptions: {
      output: {
        entryFileNames: "assets/app.js",
        assetFileNames: "assets/[name][extname]",
        codeSplitting: false,
        format: "iife",
      },
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./tests/setup.ts"],
    include: ["tests/**/*.test.{ts,tsx}"],
  },
});
