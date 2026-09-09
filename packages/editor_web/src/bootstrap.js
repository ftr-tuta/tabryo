// webview_win_floating 3.0.3 returns before WebView2 finishes registering its
// document-created scripts. The native message handler is already installed;
// create this page's bridge directly so no injected-script ordering is needed.
window.tabryoBridge = window.chrome?.webview?.postMessage
  ? {
    postMessage: message => window.chrome.webview.postMessage({
      JkChannelName: 'TabryoEditor', msg: message,
    }),
  }
  : (typeof TabryoEditor === 'undefined' ? null : TabryoEditor);
// Report failure without forwarding document text, stacks or remote telemetry.
window.addEventListener('error', () => {
  window.tabryoBridge?.postMessage(JSON.stringify({ token: location.hash.slice(1), type: 'failed' }));
});
