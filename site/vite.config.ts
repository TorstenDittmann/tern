import adapter from "@sveltejs/adapter-static";
import { enhancedImages } from "@sveltejs/enhanced-img";
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vite";

export default defineConfig({
	plugins: [
		enhancedImages(),
		sveltekit({
			// orch serves dist/404.html for any missing path, so asset URLs must
			// stay root-relative. Relative ./_app links break on nested URLs.
			paths: { relative: false },
			adapter: adapter({ pages: "dist", assets: "dist" }),
			prerender: {
				// Broken internal links fail the build.
				handleHttpError: "fail",
				handleMissingId: "fail",
			},
		}),
	],
});
