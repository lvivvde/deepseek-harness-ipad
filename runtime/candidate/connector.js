// Candidate App page connector (#17, ADR 0003). Loaded by index.html before the official entry, so the
// transport global exists before any bundle runs. It starts the fixed official Worker and relays the
// bridge's native calls to Swift; candidate frames never reach the official tunnel, which fails the
// Worker on a frame it does not know.
import {connectWorkerHost} from './client.js';

const worker = new Worker('./worker.js', {type: 'module'});
const handlers = window.webkit.messageHandlers;
worker.addEventListener('message', event => {
  const data = event.data;
  if (data?.t === 'candidate-native') {
    event.stopImmediatePropagation();
    // A reply handler: Swift answers each body with one JSON string.
    handlers.native.postMessage(data.body).then(
      text => worker.postMessage({t: 'candidate-native-reply', id: data.id, result: JSON.parse(text)}),
      error => worker.postMessage({t: 'candidate-native-reply', id: data.id, error: String(error?.message ?? error)}));
  } else if (data?.t === 'candidate-log') {
    event.stopImmediatePropagation();
    const {t, ...entry} = data;
    handlers.log.postMessage(entry);
  }
});
worker.addEventListener('error', event => handlers.log.postMessage({event: 'worker-error', message: String(event.message)}));
// Swift calls this when the user opens another project natively; the Worker registers it as a workspace.
window.candidateProjectOpened = project => worker.postMessage({t: 'candidate-project', project});
connectWorkerHost(worker).catch(error => handlers.log.postMessage({event: 'connect-failed', message: String(error?.message ?? error)}));
