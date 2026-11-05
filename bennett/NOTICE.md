# Bennett Legal modifications to DocuSeal

This image is built from the public fork <https://github.com/TheHomelessCoder/docuseal>, branch `bennett-legal`. The exact source commit is the image label `org.opencontainers.image.revision`. That fork is the complete corresponding source: DocuSeal's own `Dockerfile` builds the application from it unmodified, and `bennett/Dockerfile.bennett` adds this runtime layer.

DocuSeal is copyright DocuSeal LLC and licensed under the GNU Affero General Public License v3.0 (`/app/LICENSE`), with the additional terms in `/app/LICENSE_ADDITIONAL_TERMS`. Both files are unchanged. The original DocuSeal attribution stays visible: a "Powered by DocuSeal" link in the signer masthead, the attribution below each document, and the email attribution footer. No licence or paid-feature check is changed.

## What Bennett Legal changed

Each change is a normal commit on `bennett-legal`; `git log upstream/master..bennett-legal` lists them.

- **Recipient order before signer mutations** (2026-11-01). Form value and completion updates, uploads, prefill attachments, decline and invitation call the existing `Submitters::AuthorizedForForm` with `with_order: true`. A later signer cannot change a submission before the earlier signers finish. Upload and prefill routes also refuse view-only recipients. OTP and link authentication, lifecycle guards and prefill-token checks are unchanged. Each modified controller carries a dated notice.
- **Signer chrome and emails** (2026-11-02/03). The Bennett Legal masthead, colours and fonts; a details card, page counter and "go to where you sign" control (`public/packs/bennett-signing-v1.js`, same-origin, writes text only); the signer's stored language before the browser's; Bennett Legal invitation, verification-code and signed-copy emails in English and Spanish. Since 2026-11-04 every email uses the firm's intake nurture letterhead (`app/views/layouts/mailer.html.erb`), with dark-mode rules and DocuSeal's email attribution in its footer (`app/views/shared/_mailer_attribution.html.erb`, same text and conditions as upstream's). Signing, authorization, OTP, field and PDF logic are unchanged. The Jost and Noto Serif fonts are under the SIL Open Font License; the licence texts are in `public/fonts/`.
- **Runtime layer** (`bennett/`). `launch.rb` checks the source invariants in `source_check.rb` and the database, queue and key configuration before any service starts. `puma.rb` keeps upstream's Puma configuration and changes only the bind address. `storage.yml` stores uploaded objects with `private, no-store` cache metadata. `rds-global-bundle.pem` is the public AWS RDS trust bundle (`ca-provenance.json`).
- **Inline email artwork** (2026-11-05). `ApplicationMailer` attaches the firm's existing nurture logo and social icons as inline PNG MIME parts. The letterhead references their Content-IDs, removing its dependency on remote image downloads. The artwork, copy, links and DocuSeal attribution are unchanged.

## Source availability

Anyone receiving this image, or using the service over a network, can get the source from the public fork at the commit in the image label. Keep that fork public and keep every published image's commit reachable there (the nightly workflow tags each published commit `verified-<date>-<commit>`).
