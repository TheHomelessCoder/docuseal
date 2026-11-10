/* Keep the displayed document context in sync with the native editable title. */
(() => {
  if (window.bennettEditorContext) return;
  window.bennettEditorContext = true;
  let observer;
  const disconnect = () => { observer?.disconnect(); observer = null; };
  const initialize = () => {
    disconnect();
    const editor = document.querySelector('.bennett-staff template-builder');
    const context = document.querySelector('.bennett-editor-context');
    if (!editor || !context) return;
    const update = () => {
      const name = editor.querySelector('.template-name [contenteditable]')?.textContent.trim();
      if (!name) return;
      const title = name.replace(/^PRACTICE\s*[—–-]\s*NOT A CONTRACT\s*[—–-]\s*/i, '');
      if (context.textContent !== title) context.textContent = title;
    };
    observer = new MutationObserver(update);
    observer.observe(editor, { childList: true, subtree: true, characterData: true });
    update();
  };
  document.addEventListener('turbo:load', initialize);
  document.addEventListener('turbo:before-cache', disconnect);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
