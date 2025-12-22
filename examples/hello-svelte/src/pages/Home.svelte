<script>
  import { inertia } from "@inertiajs/svelte";

  let { name } = $props();
</script>

<svelte:head>
  <title>Home</title>
  <meta name="description" content="Hello from Svelte SSR" />
</svelte:head>

<main>
  <h1>Hello, {name}!</h1>
  <p>This page is server-side rendered with Svelte 5 and inertia_wisp_ssr.</p>
</main>
