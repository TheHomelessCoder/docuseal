/* Appearance and shell behavior only; contains no credentials or identity data. */
(() => {
  if (window.bennettStaffAppearance) return;
  window.bennettStaffAppearance = true;
  const key = 'bennett-staff-appearance';
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  let preference = 'system';
  try { preference = localStorage.getItem(key) || 'system'; } catch (_) { /* Storage is optional. */ }
  const revealNavigation = () => {
    document.querySelectorAll('.bennett-staff-nav, #account_settings_menu .menu').forEach(nav => {
      const active = nav.querySelector('[aria-current="page"]');
      if (!active || nav.scrollWidth <= nav.clientWidth) return;
      const left = active.getBoundingClientRect().left - nav.getBoundingClientRect().left + nav.scrollLeft;
      nav.scrollLeft = Math.max(0, left - (nav.clientWidth - active.getBoundingClientRect().width) / 2);
    });
  };
  const apply = () => {
    if (!['light', 'dark', 'system'].includes(preference)) preference = 'system';
    document.documentElement.dataset.staffTheme = preference;
    document.documentElement.dataset.staffColor = preference === 'system' ? (media.matches ? 'dark' : 'light') : preference;
    document.querySelectorAll('select[data-staff-theme]').forEach(select => { select.value = preference; });
    document.querySelectorAll('#account_settings_menu a[href]').forEach(link => {
      const target = new URL(link.href, window.location.href);
      if (target.origin === window.location.origin && target.pathname === window.location.pathname) link.setAttribute('aria-current', 'page');
      else link.removeAttribute('aria-current');
    });
    revealNavigation();
  };
  const closeAccount = () => document.querySelectorAll('details.bennett-staff-account[open]').forEach(menu => { menu.open = false; });
  apply();
  document.addEventListener('turbo:load', apply);
  document.addEventListener('DOMContentLoaded', apply);
  document.addEventListener('turbo:before-cache', closeAccount);
  media.addEventListener('change', apply);
  window.addEventListener('resize', revealNavigation);
  window.addEventListener('storage', event => { if (event.key === key) { preference = event.newValue || 'system'; apply(); } });
  document.addEventListener('change', event => {
    if (!(event.target instanceof Element) || !event.target.matches('select[data-staff-theme]')) return;
    preference = event.target.value;
    try { localStorage.setItem(key, preference); } catch (_) { /* Storage is optional. */ }
    apply();
  });
  document.addEventListener('click', event => {
    if (event.target instanceof Element && !event.target.closest('.bennett-staff-account')) closeAccount();
  });
  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    const menu = document.querySelector('details.bennett-staff-account[open]');
    if (!menu) return;
    const focusInside = menu.contains(document.activeElement);
    menu.open = false;
    if (focusInside) menu.querySelector('summary')?.focus();
  });
})();
