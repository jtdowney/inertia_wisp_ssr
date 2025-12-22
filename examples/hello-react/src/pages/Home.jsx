import { Head } from "@inertiajs/react";

export default function Home({ name }) {
  return (
    <>
      <Head>
        <title>Home</title>
        <meta name="description" content="Hello from React SSR" />
      </Head>
      <main>
        <h1>Hello, {name}!</h1>
        <p>This page is server-side rendered with React and inertia_wisp_ssr.</p>
      </main>
    </>
  );
}
