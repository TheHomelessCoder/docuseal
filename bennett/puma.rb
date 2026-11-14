# frozen_string_literal: true

# Puma's `load` queues config files rather than evaluating them immediately.
# Evaluate upstream in the same DSL context before replacing its listening bind,
# so its security initialization and background-job plugins actually run.
instance_eval(File.read('/app/config/puma.rb'), '/app/config/puma.rb', 1)
clear_binds!
bind ENV.fetch('DOCUSEAL_BIND', 'tcp://127.0.0.1:3000')
