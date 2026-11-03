/* Bennett Legal guided signing. Progressive enhancement over DocuSeal's signer
   page: a locked "check your details" card, a page counter and a button that
   jumps to the place to sign. Reads only data DocuSeal already renders; writes
   text with textContent; sends no requests. Removing this file restores the
   upstream page. */
(function () {
  'use strict'

  var COPY = {
    en: {
      detailsTitle: 'Please check your details',
      detailsNote: 'Bennett Legal filled these in for you, and they are locked. If anything is wrong, do not sign. Call us at (972) 972-4969.',
      name: 'Your name', fee: 'Retainer amount', date: 'Date of signing',
      goSign: 'Go to where you sign', page: 'Page', of: 'of',
      allDone: 'You have filled in everything. Press Complete to finish.'
    },
    es: {
      detailsTitle: 'Revise sus datos',
      detailsNote: 'Bennett Legal llenó estos datos por usted y no se pueden cambiar. Si algo está mal, no firme. Llámenos al (972) 972-4969.',
      name: 'Su nombre', fee: 'Monto del anticipo', date: 'Fecha de firma',
      goSign: 'Ir a donde firmar', page: 'Página', of: 'de',
      allDone: 'Ya completó todo. Presione Completar para terminar.'
    }
  }
  var LABELS = { FullName: 'name', attorney_fee: 'fee', DateSigned: 'date' }

  function parse (value, fallback) {
    try { return JSON.parse(value || '') || fallback } catch (_) { return fallback }
  }
  function el (tag, className, text) {
    var node = document.createElement(tag)
    if (className) node.className = className
    if (text != null) node.textContent = text
    return node
  }
  function language (form) {
    var lang = (form.dataset.language || document.documentElement.lang || 'en').toLowerCase()
    return lang.indexOf('es') === 0 ? 'es' : 'en'
  }
  function formatValue (kind, raw, lang) {
    var locale = lang === 'es' ? 'es-US' : 'en-US'
    if (kind === 'fee' && /^\d+(\.\d+)?$/.test(String(raw))) {
      return new Intl.NumberFormat(locale, { style: 'currency', currency: 'USD' }).format(Number(raw))
    }
    if (kind === 'date') {
      var date = raw === '{{date}}' ? new Date() : new Date(String(raw) + 'T12:00:00')
      if (!isNaN(date)) return new Intl.DateTimeFormat(locale, { dateStyle: 'long' }).format(date)
    }
    return String(raw)
  }

  function details (form, copy, lang) {
    var fields = parse(form.dataset.fields, [])
    var values = parse(form.dataset.values, {})
    var submitter = parse(form.dataset.submitter, {})
    var rows = []
    fields.forEach(function (field) {
      var kind = LABELS[field.name]
      if (!kind || field.readonly !== true || field.submitter_uuid !== submitter.uuid) return
      var raw = values[field.uuid] != null && values[field.uuid] !== '' ? values[field.uuid] : field.default_value
      if (raw == null || raw === '') return
      rows.push([copy[kind], formatValue(kind, raw, lang)])
    })
    if (!rows.length) return null
    var card = el('section', 'bennett-guide-details')
    card.setAttribute('aria-labelledby', 'bennett-guide-details-title')
    var title = el('h2', 'bennett-guide-details__title', copy.detailsTitle)
    title.id = 'bennett-guide-details-title'
    card.appendChild(title)
    var list = el('dl', 'bennett-guide-details__list')
    rows.forEach(function (row) {
      var item = el('div', 'bennett-guide-details__row')
      item.appendChild(el('dt', null, row[0]))
      item.appendChild(el('dd', null, row[1]))
      list.appendChild(item)
    })
    card.appendChild(list)
    card.appendChild(el('p', 'bennett-guide-details__note', copy.detailsNote))
    return card
  }

  function signTarget () {
    return document.querySelector('.field-area-active') ||
      document.querySelector('.field-area.cursor-pointer.bg-opacity-80')
  }
  function goToSign () {
    var target = signTarget()
    var expand = document.querySelector('.expand-form-button')
    if (expand && expand.offsetParent !== null) expand.click()
    if (!target) return false
    target.scrollIntoView({ block: 'start', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' })
    return true
  }

  function navigation (pages, copy) {
    var bar = el('nav', 'bennett-guide-nav')
    bar.setAttribute('aria-label', copy.goSign)
    var counter = el('span', 'bennett-guide-nav__page')
    counter.setAttribute('aria-live', 'polite')
    var button = el('button', 'bennett-guide-nav__go', copy.goSign)
    button.type = 'button'
    var status = el('span', 'bennett-guide-nav__status')
    status.setAttribute('role', 'status')
    button.addEventListener('click', function () { status.textContent = goToSign() ? '' : copy.allDone })
    bar.appendChild(counter)
    bar.appendChild(button)
    bar.appendChild(status)

    var visible = new Map()
    function render () {
      var best = 0; var ratio = -1
      pages.forEach(function (page, index) {
        var r = visible.get(page) || 0
        if (r > ratio) { ratio = r; best = index }
      })
      counter.textContent = copy.page + ' ' + (best + 1) + ' ' + copy.of + ' ' + pages.length
    }
    if ('IntersectionObserver' in window) {
      var observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) { visible.set(entry.target, entry.intersectionRatio) })
        render()
      }, { threshold: [0, 0.25, 0.5, 0.75, 1] })
      pages.forEach(function (page) { observer.observe(page) })
    }
    render()
    return bar
  }

  function start () {
    var form = document.querySelector('submission-form')
    var firstDocument = document.querySelector('[id^="document-"]')
    if (!form || !firstDocument || document.querySelector('.bennett-guide')) return
    var lang = language(form)
    var copy = COPY[lang]
    var pages = Array.prototype.slice.call(document.querySelectorAll('page-container'))
    var guide = el('div', 'bennett-guide')
    guide.lang = lang
    var card = details(form, copy, lang)
    if (card) guide.appendChild(card)
    firstDocument.parentNode.insertBefore(guide, firstDocument)
    if (!pages.length) return
    var nav = navigation(pages, copy)
    firstDocument.parentNode.insertBefore(nav, firstDocument)
    // Pin below DocuSeal's own sticky title bar, whose height varies by width.
    var header = document.getElementById('signing_form_header')
    function pin () {
      var sticky = header && getComputedStyle(header).position === 'sticky'
      // The header overlaps the page by its -4px bottom margin.
      nav.style.top = sticky ? Math.max(0, header.getBoundingClientRect().height - 4) + 'px' : '0px'
    }
    pin()
    window.addEventListener('resize', pin)
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start)
  else start()
})()
