// #23 acceptance: the workspace reaches Linux over 9P, where the guest gets no change events for
// native writes, so the watcher polls. The dev server runs read-only on the workspace: its cache lives in /tmp.
export default {
  cacheDir: '/tmp/vite-hmr-acceptance',
  server: {
    watch: { usePolling: true, interval: 100 },
  },
};
