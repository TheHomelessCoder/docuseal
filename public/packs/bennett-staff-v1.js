/* JUD-style appearance preference; contains no credentials or identity data. */
(() => {
  if (window.bennettStaffAppearance) return;
  window.bennettStaffAppearance = true;
  const key = 'bennett-staff-appearance';
  let preference = 'system';
  try { preference = localStorage.getItem(key) || 'system'; } catch (_) { /* Storage is optional. */ }
  const apply = () => {
    if (!['light', 'dark', 'system'].includes(preference)) preference = 'system';
    document.documentElement.dataset.staffTheme = preference;
    document.querySelectorAll('[data-staff-theme]').forEach(select => { select.value = preference; });
  };
  apply();
  document.addEventListener('turbo:load', apply);
  document.addEventListener('DOMContentLoaded', apply);
  document.addEventListener('change', event => {
    if (!(event.target instanceof Element) || !event.target.matches('[data-staff-theme]')) return;
    preference = event.target.value;
    try { localStorage.setItem(key, preference); } catch (_) { /* Storage is optional. */ }
    apply();
  });
})();
