/* Synthetic browser checks for signer chrome. No service or real document is opened. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

const repo = path.resolve(__dirname, '../..');
// Playwright comes from the smoke-test package (bennett/ci/package-lock.json).
const { chromium } = createRequire(path.join(repo, 'bennett/ci/package.json'))('playwright');
const packs = path.join(repo, 'public/packs');
const fonts = path.join(repo, 'public/fonts');
let css = fs.readFileSync(path.join(packs, 'bennett-signing-v1.css'), 'utf8');
for (const name of ['bennett-jost-latin.woff2', 'bennett-noto-serif-latin.woff2']) {
  const data = fs.readFileSync(path.join(fonts, name)).toString('base64');
  css = css.replace(`/fonts/${name}`, `data:font/woff2;base64,${data}`);
}

const logo = `data:image/png;base64,${fs.readFileSync(path.join(packs, 'bennett-legal-logo-white.png')).toString('base64')}`;
const banner = language => `<div class="bennett-masthead">
  <div class="bennett-masthead__identity"><img class="bennett-masthead__logo" src="${logo}" width="512" height="220" alt="Bennett Legal"></div>
  <div class="bennett-masthead__attribution"><span>${language === 'es' ? 'Desarrollado por' : 'Powered by'}</span>
    <a class="bennett-masthead__vendor" href="https://example.invalid/"><span>DocuSeal</span></a></div>
</div>`;

async function run() {
  const launch = { headless: true };
  if (process.env.CHROME_PATH) launch.executablePath = process.env.CHROME_PATH;
  const browser = await chromium.launch(launch);
  try {
    const page = await browser.newPage();
    await page.route('**/*', route => route.abort());
    for (const width of [320, 375, 768, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      for (const language of ['en', 'es']) {
        await page.setContent(`<!doctype html><html lang="${language}"><head><style>
          * { box-sizing: border-box } body { margin: 0 } .max-w-md { max-width: 28rem }
          .btn { display: flex; align-items: center; justify-content: center; padding: 0 1rem; border: 1px solid }
          .bg-base-200 { background: #efeae6 } .rounded-xl { border-radius: .75rem }
          .p-4 { padding: 1rem } .w-full { width: 100% }
        </style></head><body class="bennett-signer"><main><div class="max-w-md">${banner(language)}
          <div class="bg-base-200 rounded-xl p-4"><p>TEST ONLY — ${language === 'es' ? 'Verificación por correo electrónico' : 'Email verification'}</p></div>
          <button class="base-button btn w-full">${language === 'es' ? 'Enviar código de verificación' : 'Send verification code'}</button>
          <a href="https://example.invalid/">DocuSeal</a></div></main></body></html>`);
        await page.addStyleTag({ content: css });
        await page.evaluate(() => document.fonts.ready);
        const measurements = await page.evaluate(() => {
          const box = element => { const r = element.getBoundingClientRect(); return { left: r.left, right: r.right, width: r.width, height: r.height }; };
          return { viewport: document.documentElement.clientWidth, page: document.documentElement.scrollWidth,
            identity: box(document.querySelector('.bennett-masthead__identity')),
            vendor: box(document.querySelector('.bennett-masthead__attribution')),
            button: box(document.querySelector('.base-button')),
            mastheadBackground: getComputedStyle(document.querySelector('.bennett-masthead')).backgroundColor,
            buttonBackground: getComputedStyle(document.querySelector('.base-button')).backgroundColor,
            buttonText: getComputedStyle(document.querySelector('.base-button')).color,
            logo: (({ naturalWidth, alt }, r) => ({ naturalWidth, alt, width: r.width, height: r.height }))(
              document.querySelector('.bennett-masthead__logo'), document.querySelector('.bennett-masthead__logo').getBoundingClientRect()),
            link: document.querySelector('.bennett-masthead__vendor').textContent.trim() };
        });
        assert.ok(measurements.page <= measurements.viewport, `horizontal overflow: ${width}/${language}`);
        assert.ok(measurements.identity.right <= measurements.vendor.left + 0.5, `masthead overlap: ${width}/${language}`);
        assert.ok(measurements.vendor.right <= width, `attribution clipped: ${width}/${language}`);
        assert.ok(measurements.button.height >= 44, `button too small: ${width}/${language}`);
        assert.equal(measurements.mastheadBackground, 'rgb(11, 17, 32)');
        assert.equal(measurements.buttonBackground, 'rgb(245, 179, 36)');
        assert.equal(measurements.buttonText, 'rgb(15, 23, 42)');
        const luminance = rgb => {
          const channels = rgb.match(/\d+/g).map(value => Number(value) / 255)
            .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
          return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
        };
        const values = [luminance(measurements.buttonBackground), luminance(measurements.buttonText)].sort((a, b) => b - a);
        assert.ok((values[0] + 0.05) / (values[1] + 0.05) >= 4.5, 'primary action contrast is insufficient');
        assert.equal(measurements.logo.naturalWidth, 512, 'logo did not load');
        assert.equal(measurements.logo.alt, 'Bennett Legal');
        assert.ok(measurements.logo.height >= 36 && measurements.logo.width >= 80, `logo too small: ${width}/${language}`);
        assert.equal(measurements.link, 'DocuSeal');

        // Exercise a representative DocuSeal step panel, including the Spanish
        // labels and a narrow phone. The PDF below is a synthetic page only.
        await page.setContent(`<!doctype html><html lang="${language}"><head><style>
          * { box-sizing: border-box } body { margin: 0 }
          .field-name-label { display: block; font-size: 20px; line-height: 1.3; margin-bottom: 12px }
          .base-input { display: block; width: 100%; height: 48px; border: 1px solid; background: white }
          .text-gray-300 { color: rgb(156, 163, 175) }
          .base-button { display: flex; justify-content: center; align-items: center; width: 100%; margin-top: 12px; border: 1px solid }
          #form_container { position: fixed; bottom: 0; left: 50%; transform: translateX(-50%); width: min(100%, 700px); padding: 16px; background: white }
        </style></head><body class="bennett-signer"><main><div id="form_container">
          <label class="field-name-label" for="test-field">${language === 'es' ? 'Nombre completo del cliente' : 'Client full name'}</label>
          <input id="test-field" class="base-input" value="Synthetic test" />
          <select class="base-input text-gray-300" aria-label="Test selector"><option>${language === 'es' ? 'Seleccione una opción' : 'Select an option'}</option></select>
          <button class="base-button" type="button">${language === 'es' ? 'Continuar' : 'Continue'}</button>
        </div></main></body></html>`);
        await page.addStyleTag({ content: css });
        await page.evaluate(() => document.fonts.ready);
        const panel = await page.evaluate(() => {
          const rect = document.querySelector('#form_container').getBoundingClientRect();
          const control = document.querySelector('.base-button').getBoundingClientRect();
          return { viewport: document.documentElement.clientWidth, page: document.documentElement.scrollWidth,
            left: rect.left, right: rect.right, bottom: rect.bottom, height: rect.height,
            buttonHeight: control.height, buttonBottom: control.bottom,
            labelFont: getComputedStyle(document.querySelector('.field-name-label')).fontFamily,
            placeholder: getComputedStyle(document.querySelector('select')).color };
        });
        assert.ok(panel.page <= panel.viewport, `step panel horizontal overflow: ${width}/${language}`);
        assert.ok(panel.left >= 0 && panel.right <= width && panel.bottom <= 900, `step panel clipped: ${width}/${language}`);
        assert.ok(panel.height < 450 && panel.buttonBottom <= 900, `step panel hides its action: ${width}/${language}`);
        assert.ok(panel.buttonHeight >= 44, `step button too small: ${width}/${language}`);
        assert.match(panel.labelFont, /Bennett Noto Serif/);
        assert.equal(panel.placeholder, 'rgb(156, 163, 175)', `unselected option indication changed: ${width}/${language}`);
        await page.keyboard.press('Tab');
        const focus = await page.evaluate(() => ({ id: document.activeElement.id, outline: getComputedStyle(document.activeElement).outlineWidth }));
        assert.equal(focus.id, 'test-field', `keyboard did not reach the input: ${width}/${language}`);
        assert.equal(focus.outline, '3px', `keyboard focus is not visible: ${width}/${language}`);
        await page.locator('.base-button').evaluate(element => element.addEventListener('click', () => { element.dataset.clicks = String(Number(element.dataset.clicks || 0) + 1); }));
        await page.locator('.base-button').click();
        await page.locator('.base-button').focus();
        await page.keyboard.press('Enter');
        assert.equal(await page.locator('.base-button').getAttribute('data-clicks'), '2');
      }
      // The overlay must not move or restyle an existing positioned PDF field.
      await page.setContent(`<!doctype html><html><body class="bennett-signer"><main>${banner('en')}
        <page-container style="display:block;position:relative;width:100%;height:600px;background:white;color:black;font-family:serif">
        <field-value style="display:block;position:absolute;left:24%;top:61%;width:31%;height:5%">Synthetic value</field-value>
        </page-container></main></body></html>`);
      const geometry = () => page.evaluate(() => {
        const parent = document.querySelector('page-container').getBoundingClientRect();
        const field = document.querySelector('field-value'); const box = field.getBoundingClientRect();
        return { left: box.left - parent.left, top: box.top - parent.top, width: box.width, height: box.height,
                 font: getComputedStyle(field).fontFamily, color: getComputedStyle(field).color };
      });
      const before = await geometry();
      await page.addStyleTag({ content: css });
      assert.deepEqual(await geometry(), before, `PDF field geometry or appearance changed: ${width}`);
      // Locked values drawn on a page (name, date, fee) inherit page text color,
      // not the white chrome text. Native pages set no inline color.
      await page.locator('page-container').evaluate(element => element.style.removeProperty('color'));
      assert.equal(await page.locator('field-value').evaluate(element => getComputedStyle(element).color), 'rgb(0, 0, 0)',
        `locked document values are not dark: ${width}`);
    }
    // Inactive native controls must keep their disabled appearance.
    await page.setContent('<!doctype html><head><style>.base-button { background: grey; color: white }</style></head><body class="bennett-signer"><button class="base-button" disabled>Disabled</button><button class="base-button btn-disabled">Unavailable</button></body>');
    const disabled = () => page.locator('button').evaluateAll(elements => elements.map(element => ({ background: getComputedStyle(element).backgroundColor, color: getComputedStyle(element).color })));
    const beforeDisabled = await disabled();
    await page.addStyleTag({ content: css });
    assert.deepEqual(await disabled(), beforeDisabled, 'disabled action appearance changed');
    await page.setContent('<!doctype html><body class="bennett-signer"><button class="base-button" style="padding:0;border:0">Test</button></body>');
    const mutant = css.replaceAll('min-height: 44px;', 'min-height: 12px;');
    assert.notEqual(mutant, css, 'touch-target mutation was not applied');
    await page.addStyleTag({ content: mutant });
    assert.ok((await page.locator('.base-button').boundingBox()).height < 44, 'touch-target control did not catch the mutation');
    // Guided signing: locked details are rendered as text only, belong to this
    // signer, follow the signer's language, and the jump reaches the active field.
    const guideJs = fs.readFileSync(path.join(packs, 'bennett-signing-v1.js'), 'utf8');
    const hostile = '<img src=x onerror="window.__owned=1">';
    const fields = [
      { uuid: 'f1', submitter_uuid: 'me', name: 'FullName', type: 'text', readonly: true, default_value: hostile },
      { uuid: 'f2', submitter_uuid: 'me', name: 'attorney_fee', type: 'text', readonly: true, default_value: '3000' },
      { uuid: 'f3', submitter_uuid: 'me', name: 'DateSigned', type: 'date', readonly: true, default_value: '{{date}}' },
      { uuid: 'f4', submitter_uuid: 'other', name: 'FullName', type: 'text', readonly: true, default_value: 'Someone Else' },
      { uuid: 'f5', submitter_uuid: 'me', name: 'Signature', type: 'signature', readonly: false }];
    const attr = value => JSON.stringify(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;');
    for (const language of ['en', 'es']) {
      // A fresh document per language: setContent can keep the previous
      // pass's scroll position, and the page counter follows the scroll.
      await page.goto('about:blank');
      await page.setViewportSize({ width: 390, height: 700 });
      await page.setContent(`<!doctype html><html lang="${language}"><body class="bennett-signer"><main>
        <div id="signing_form_header" style="position:sticky;top:0;height:80px">Header</div>
        <div><div id="document-x">${[0, 1, 2].map(i => `<page-container style="display:block;position:relative;height:900px;background:white">
          ${i === 2 ? '<div class="field-area field-area-active" style="position:absolute;top:600px;left:10px;width:100px;height:40px">sign</div>' : ''}</page-container>`).join('')}</div></div>
        <submission-form data-language="${language}" data-fields="${attr(fields)}" data-values="${attr({})}" data-submitter="${attr({ uuid: 'me' })}"></submission-form>
        </main></body></html>`);
      await page.addStyleTag({ content: css });
      await page.addScriptTag({ content: guideJs });
      const guideState = await page.evaluate(() => ({
        title: document.querySelector('.bennett-guide-details__title')?.textContent,
        rows: [...document.querySelectorAll('.bennett-guide-details__row')].map(row => [row.querySelector('dt').textContent, row.querySelector('dd').textContent]),
        injected: document.querySelectorAll('.bennett-guide img').length + (window.__owned ? 1 : 0),
        counter: document.querySelector('.bennett-guide-nav__page')?.textContent }));
      assert.equal(guideState.title, language === 'es' ? 'Revise sus datos' : 'Please check your details');
      assert.equal(guideState.injected, 0, 'details card rendered markup from field data');
      assert.equal(guideState.rows.length, 3, 'details card must show only this signer\'s locked values');
      assert.equal(guideState.rows[0][1], hostile);
      assert.ok(guideState.rows[1][1].includes('3,000.00'), `fee not formatted: ${guideState.rows[1][1]}`);
      assert.ok(!guideState.rows.some(row => row[1] === 'Someone Else'));
      assert.match(guideState.counter, language === 'es' ? /^Página 1 de 3$/ : /^Page 1 of 3$/);
      await page.locator('.bennett-guide-nav__go').click();
      await page.waitForFunction(() => { const r = document.querySelector('.field-area-active').getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; });
      const navBox = await page.locator('.bennett-guide-nav').boundingBox();
      const header = await page.evaluate(() => document.getElementById('signing_form_header').getBoundingClientRect().height);
      assert.ok(Math.abs(navBox.y - (header - 4)) <= 1, `jump bar is not pinned below the title bar: ${navBox.y} vs ${header}`);
      assert.ok(navBox.height >= 48, 'jump control too small');
    }
    console.log('Signer chrome: 8 verification layouts, 8 interactive step panels, and 4 document geometry controls, and 2 guided-signing checks passed.');
  } finally {
    await browser.close();
  }
}

run().catch(error => { console.error(error.message); process.exitCode = 1; });
