// Report failure without forwarding document text, stacks or remote telemetry.
window.addEventListener('error', () => {
  if (typeof TabryoEditor !== 'undefined') {
    TabryoEditor.postMessage(JSON.stringify({ token: location.hash.slice(1), type: 'failed' }));
  }
});
