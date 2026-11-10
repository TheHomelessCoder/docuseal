(() => {
  function initialize() {
    document.querySelectorAll('.bennett-settings-disclosure:not([data-initialized])').forEach(disclosure => {
      disclosure.dataset.initialized = 'true';
      const links = Array.from(disclosure.querySelectorAll('#account_settings_menu a[href]'));
      const current = links.find(link => new URL(link.href, location.href).pathname === location.pathname);
      const label = disclosure.querySelector('[data-settings-current]');
      if (current && label) label.textContent = current.textContent.trim();
      if (matchMedia('(max-width: 767px)').matches) disclosure.open = false;
    });
  }
  if (!window.bennettSettingsInitialized) {
    window.bennettSettingsInitialized = true;
    document.addEventListener('turbo:load', initialize);
    document.addEventListener('DOMContentLoaded', initialize);
  }
  initialize();
})();
