const {flushCompileCache} = require('node:module');
if (process.env.NODE_COMPILE_CACHE && flushCompileCache) {
  for (const seconds of [180, 300, 600]) setTimeout(flushCompileCache, seconds * 1000).unref();
}
