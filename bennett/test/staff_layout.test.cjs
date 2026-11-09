/* Render the real staff navbar ERB, then exercise its actual CSS and theme JS.
 * The submission content is synthetic; no account, service or document is opened. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createRequire } = require('node:module');
const root = path.resolve(__dirname, '../..');
const { chromium } = createRequire(path.join(root, 'bennett/ci/package.json'))('playwright');
const ruby = `require 'erb'; require 'cgi'; require ARGV.fetch(1)
class StaffFixture
  include BennettStaffHelper
  Name = Struct.new(:text) { def presence = text }
  Person = Struct.new(:email) { def full_name = Name.new('Staff Reviewer') }
  def true_user = Person.new('reviewer@example.test')
  def bennett_staff_signed_in? = true
  def request = Struct.new(:path).new('/submissions')
  def controller_name = 'submissions_dashboard'
  def params = {status: 'completed'}
  def submissions_path(status: nil) = status ? '/submissions?status=completed' : '/submissions'
  def root_path = '/'
  def templates_path = '/templates'
  def settings_profile_index_path = '/settings/profile'
  def destroy_user_session_path = '/sign_out'
  def t(*) = 'Sign out'
  def link_to(label, href, aria: {})
    current = aria[:current] ? ' aria-current="page"' : ''
    '<a href="' + CGI.escapeHTML(href) + '"' + current + '>' + CGI.escapeHTML(label) + '</a>'
  end
  def button_to(label, href, **options)
    '<form><button class="' + options[:class] + '">' + CGI.escapeHTML(label) + '</button></form>'
  end
  def render(file) = ERB.new(File.read(file)).result(binding)
end
print StaffFixture.new.render(ARGV.fetch(0))`;
const rendered = spawnSync('ruby', ['-e', ruby, path.join(root, 'app/views/shared/_bennett_staff_navbar.html.erb'), path.join(root, 'app/helpers/bennett_staff_helper.rb')], { encoding: 'utf8' });
assert.equal(rendered.status, 0, rendered.stderr);
const logo = `data:image/png;base64,${fs.readFileSync(path.join(root, 'public/packs/bennett-legal-logo-white.png')).toString('base64')}`;
const navbar = rendered.stdout.replace('/packs/bennett-legal-logo-white.png', logo);
const css = fs.readFileSync(path.join(root, 'public/packs/bennett-staff-v1.css'), 'utf8')
  .replace('/fonts/bennett-jost-latin.woff2', `data:font/woff2;base64,${fs.readFileSync(path.join(root, 'public/fonts/bennett-jost-latin.woff2')).toString('base64')}`);
const js = fs.readFileSync(path.join(root, 'public/packs/bennett-staff-v1.js'), 'utf8');

async function run() {
  const launch = { headless: true };
  if (process.env.CHROME_PATH) launch.executablePath = process.env.CHROME_PATH;
  const browser = await chromium.launch(launch);
  try {
    for (const width of [320, 375, 768, 1280]) {
      for (const preference of ['light', 'dark', 'system']) {
        const page = await browser.newPage({ viewport: { width, height: 900 }, colorScheme: 'dark' });
        const errors = [];
        page.on('pageerror', error => errors.push(error.message));
        await page.route('**/*', route => route.abort());
        await page.setContent(`<!doctype html><html data-theme="docuseal"><head><style>${css}
          main { max-width: 72rem; margin: auto; padding: 1rem } .base-input,.base-button { min-height: 2.75rem; border: 1px solid; padding: .5rem 1rem }
        </style></head><body class="bennett-staff">${navbar}<main><h1>Completed submissions</h1>
          <p>PRACTICE — NOT A CONTRACT</p><button class="base-button">Download signed PDF</button>
          <p><a href="/submissions/4/events">Event timeline</a></p><input class="base-input" aria-label="Search" placeholder="Search submissions">
          </main><footer class="bennett-staff-footer"><span>Bennett Legal · Signing workspace</span><a href="https://www.docuseal.com">Powered by DocuSeal</a></footer></body></html>`);
        await page.addScriptTag({ content: js });
        await page.locator('.bennett-staff-account summary').click();
        await page.getByLabel('Appearance', { exact: true }).selectOption(preference);
        await page.evaluate(() => document.fonts.ready);
        const measurement = await page.evaluate(() => ({
          viewport: document.documentElement.clientWidth, width: document.documentElement.scrollWidth,
          background: getComputedStyle(document.body).backgroundColor,
          text: getComputedStyle(document.body).color,
          theme: document.documentElement.dataset.staffTheme,
          brand: getComputedStyle(document.querySelector('.bennett-staff-brand')).color,
          logoLoaded: document.querySelector('.bennett-staff-brand img').naturalWidth > 0,
          selectHeight: document.querySelector('[data-staff-theme]').getBoundingClientRect().height,
          active: document.querySelector('[aria-current="page"]').textContent.trim()
        }));
        assert.ok(measurement.width <= measurement.viewport, `page overflow at ${width}/${preference}`);
        assert.equal(measurement.background, preference === 'light' ? 'rgb(248, 250, 252)' : 'rgb(17, 19, 21)');
        assert.equal(measurement.theme, preference);
        assert.equal(measurement.brand, 'rgb(241, 245, 249)');
        assert.ok(measurement.logoLoaded);
        assert.ok(measurement.selectHeight >= 36);
        assert.equal(measurement.active, 'Completed');
        assert.equal(await page.getByRole('link', { name: 'Templates', exact: true }).getAttribute('href'), '/templates');
        if (preference === 'system') {
          await page.emulateMedia({ colorScheme: 'light' });
          await page.waitForFunction(() => document.documentElement.dataset.staffColor === 'light');
          assert.equal(await page.evaluate(() => getComputedStyle(document.body).backgroundColor), 'rgb(248, 250, 252)');
          await page.emulateMedia({ colorScheme: 'dark' });
          await page.waitForFunction(() => document.documentElement.dataset.staffColor === 'dark');
        }
        await page.keyboard.press('Escape');
        assert.equal(await page.locator('.bennett-staff-account').getAttribute('open'), null);
        // Turbo renders the selected destination on the server. Its active
        // item must stay in view when a compact navigation bar scrolls.
        const activeNavigation = await page.evaluate(() => {
          const nav = document.querySelector('.bennett-staff-nav');
          nav.querySelector('[aria-current]').removeAttribute('aria-current');
          const active = nav.querySelector('a:last-child');
          active.setAttribute('aria-current', 'page');
          document.dispatchEvent(new Event('turbo:load'));
          const container = nav.getBoundingClientRect();
          const item = active.getBoundingClientRect();
          return { left: item.left - container.left, right: item.right - container.right };
        });
        assert.ok(activeNavigation.left >= -1 && activeNavigation.right <= 1, `active navigation clipped at ${width}`);
        assert.deepEqual(errors, []);
        if (process.env.STAFF_SCREENSHOT_DIR && width === 1280 && preference !== 'system') {
          fs.mkdirSync(process.env.STAFF_SCREENSHOT_DIR, { recursive: true });
          await page.screenshot({ path: path.join(process.env.STAFF_SCREENSHOT_DIR, `staff-${preference}.png`), fullPage: true });
        }
        await page.close();
      }
    }
    console.log('Staff layout: 12 viewport/appearance combinations passed.');
  } finally { await browser.close(); }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
