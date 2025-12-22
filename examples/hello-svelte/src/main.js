import { createInertiaApp } from "@inertiajs/svelte";
import { hydrate, mount } from "svelte";

createInertiaApp({
  resolve: (name) => {
    const pages = import.meta.glob("./pages/**/*.svelte", { eager: true });
    return pages[`./pages/${name}.svelte`];
  },
  setup({ el, App, props }) {
    hydrate(App, { target: el, props });
  },
});
