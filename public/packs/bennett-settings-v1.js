(() => {
  const desktop = matchMedia('(min-width: 768px)');
  function initialize() {
    document.querySelectorAll('.bennett-settings-disclosure:not([data-initialized])').forEach(disclosure => {
      disclosure.dataset.initialized = 'true';
      const links = Array.from(disclosure.querySelectorAll('#account_settings_menu a[href]'));
      const current = links.find(link => {
        const target = new URL(link.href, location.href);
        return target.origin === location.origin && target.pathname === location.pathname;
      });
      const label = disclosure.querySelector('[data-settings-current]');
      if (current && label) label.textContent = current.textContent.trim();
      disclosure.open = desktop.matches;
    });
  }
  if (!window.bennettSettingsInitialized) {
    window.bennettSettingsInitialized = true;
    let escapeSummary;
    document.addEventListener('turbo:load', initialize);
    document.addEventListener('DOMContentLoaded', initialize);
    desktop.addEventListener('change', () => {
      document.querySelectorAll('.bennett-settings-disclosure').forEach(disclosure => {
        const focusInside = disclosure.contains(document.activeElement);
        disclosure.open = desktop.matches;
        if (!desktop.matches && focusInside) disclosure.querySelector('summary')?.focus();
      });
    });
    document.addEventListener('keydown', event => {
      if (event.key !== 'Escape' || desktop.matches) return;
      const disclosure = document.querySelector('.bennett-settings-disclosure[open]');
      if (!disclosure?.contains(document.activeElement)) return;
      disclosure.open = false;
      escapeSummary = disclosure.querySelector('summary');
      escapeSummary?.focus();
    });
    // Upstream blurs the active element on Escape keyup. Keep focus on this
    // disclosure only when its own keyboard handler closed the section list.
    document.addEventListener('keyup', event => {
      if (event.key !== 'Escape' || !escapeSummary) return;
      const summary = escapeSummary;
      escapeSummary = null;
      if (!summary.isConnected) return;
      event.stopPropagation();
      summary.focus();
    }, true);
  }
  initialize();
})();
