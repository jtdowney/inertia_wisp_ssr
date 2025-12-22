import { createInertiaApp } from '@inertiajs/svelte'
import { render as renderToString } from 'svelte/server'

const pages = import.meta.glob('./pages/**/*.svelte', { eager: true })

export async function render(page) {
  return createInertiaApp({
    page,
    resolve: (name) => pages[`./pages/${name}.svelte`],
    setup({ App, props }) {
      return renderToString(App, { props })
    },
  })
}
