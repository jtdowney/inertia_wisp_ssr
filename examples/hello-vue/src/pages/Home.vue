<script setup>
import { Head } from "@inertiajs/vue3";

defineProps({
  name: String,
});
</script>

<template>
  <Head>
    <title>Home</title>
    <meta name="description" content="Hello from Vue SSR" />
  </Head>
  <main>
    <h1>Hello, {{ name }}!</h1>
    <p>This page is server-side rendered with Vue and inertia_wisp_ssr.</p>
  </main>
</template>
