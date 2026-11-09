# frozen_string_literal: true

# An incomplete opt-in must reject the candidate at boot, never expose a
# password fallback on a misconfigured staff host.
require Rails.root.join('lib/bennett/staff_access')

Bennett::StaffAccess.configuration if Bennett::StaffAccess.enabled?
