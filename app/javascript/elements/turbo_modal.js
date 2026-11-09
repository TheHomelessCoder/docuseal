import { actionable } from '@github/catalyst/lib/actionable'

export default actionable(class extends HTMLElement {
  connectedCallback () {
    document.body.classList.add('overflow-hidden')

    if (document.body.classList.contains('bennett-staff') && this.getAttribute('role') === 'dialog') {
      this.staffReturnFocus = document.activeElement
      this.setAttribute('tabindex', '-1')
      this.staffFocusFrame = window.requestAnimationFrame(() => {
        if (this.isConnected) (this.staffFocusable()[0] || this).focus()
      })
      document.addEventListener('keydown', this.onStaffTab)
    }

    document.addEventListener('keyup', this.onEscKey)

    document.addEventListener('turbo:before-cache', this.onBeforeCache)

    if (this.dataset.closeAfterSubmit !== 'false') {
      document.addEventListener('turbo:submit-end', this.onSubmit)
    }
  }

  disconnectedCallback () {
    document.body.classList.remove('overflow-hidden')

    document.removeEventListener('keyup', this.onEscKey)
    document.removeEventListener('turbo:submit-end', this.onSubmit)
    document.removeEventListener('turbo:before-cache', this.onBeforeCache)
    document.removeEventListener('keydown', this.onStaffTab)
    if (this.staffFocusFrame) window.cancelAnimationFrame(this.staffFocusFrame)
    if (this.staffReturnFocus?.isConnected) this.staffReturnFocus.focus({ preventScroll: true })
  }

  staffFocusable = () => Array.from(this.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), summary, [tabindex]:not([tabindex="-1"])'))
    .filter(element => element.getClientRects().length && !element.closest('[hidden], [inert]'))

  onStaffTab = (event) => {
    if (event.key !== 'Tab') return
    const items = this.staffFocusable()
    const first = items[0]
    const last = items[items.length - 1]
    if (!first) { event.preventDefault(); this.focus(); return }
    if (!this.contains(document.activeElement) || (event.shiftKey && document.activeElement === first)) {
      event.preventDefault()
      ;(event.shiftKey ? last : first).focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  onSubmit = (e) => {
    if (e.detail.success && e.detail?.formSubmission?.formElement?.dataset?.closeOnSubmit !== 'false') {
      this.close()
    }
  }

  onEscKey = (e) => {
    if (e.code === 'Escape') {
      this.close()
    }
  }

  onBeforeCache = () => {
    if (this.closest('turbo-frame')?.src) {
      this.remove()
    }
  }

  close = (e) => {
    e?.preventDefault()

    this.remove()
  }
})
