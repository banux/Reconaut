# frozen_string_literal: true

# Rake task `bin/rails reconaut:doctor` : self-check d'une instance.
#
# Source de verite :
#   openspec/changes/add-tech-stack/tasks.md section 6 ("commande
#     bin/doctor / Rake task rails reconaut:doctor")
#   openspec/changes/add-graph-retrieval/tasks.md section 7.1
#
# La task imprime un rapport JSON et exit avec 0 / 1 selon la
# coherence des checks. Les probes vers la DB sont injectables :
# en l'absence de DB live, elles renvoient un statut explicite plutot
# que de planter.

require "json"

namespace :reconaut do
  desc "Self-check : extension AGE, region EU, lag de projection, role reader, provider d'embedder"
  task doctor: :environment do
    require "reconaut/doctor"

    probes = {
      age_loaded?: ->(_ctx) {
        return false unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

        result = ActiveRecord::Base.connection.execute(
          "SELECT count(*) AS n FROM pg_extension WHERE extname = 'age'"
        )
        Integer(result.first.fetch("n", 0)) > 0
      rescue StandardError
        false
      },
      region: ->(_ctx) { ENV["RECONAUT_REGION"] },
      graph_lag_p95: ->(_ctx) {
        ENV["RECONAUT_GRAPH_LAG_P95_SECONDS"]&.then { |v| Float(v) rescue nil }
      },
      graph_role_can_write?: ->(_ctx) {
        return true unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
        # Heuristique : on regarde si le rôle courant a INSERT sur les
        # tables AGE du schema "reconaut". S'il en a, c'est qu'on
        # n'utilise pas le reader -> fail.
        result = ActiveRecord::Base.connection.execute(
          "SELECT has_schema_privilege(current_user, 'reconaut', 'CREATE') AS can_write"
        )
        result.first["can_write"] == "t" || result.first["can_write"] == true
      rescue StandardError
        true
      },
      good_jobs_pending: ->(_ctx) {
        return nil unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

        result = ActiveRecord::Base.connection.execute(
          "SELECT count(*)::int AS n FROM good_jobs WHERE finished_at IS NULL"
        )
        Integer(result.first.fetch("n", 0))
      rescue StandardError
        nil
      },
      last_worker_heartbeat: ->(_ctx) {
        # Lit le dernier heartbeat reçu via le tool MCP submit_heartbeat
        # (cf. add-tech-stack §6 + reconaut/heartbeats.rb). Si aucun
        # worker ne s'est encore annoncé, renvoie nil et le probe passe
        # en :unknown.
        latest = Reconaut::Registry.default.heartbeat_store.latest
        latest&.to_h
      rescue StandardError
        nil
      }
    }

    report = Reconaut::Doctor.run(probes: probes, env: ENV)
    puts JSON.pretty_generate(report.to_h)
    exit report.exit_code
  end

  desc "Pose le password de l'opérateur unique. Idempotent : refuse si un user existe " \
       "deja sauf si RECONAUT_ROTATE=true (qui rote le password ET révoque toutes les " \
       "clés API existantes). Lit RECONAUT_OPERATOR_PASSWORD."
  task set_password: :environment do
    require "reconaut/auth/bootstrap"

    email    = ENV["RECONAUT_OPERATOR_EMAIL"].to_s.strip
    password = ENV["RECONAUT_OPERATOR_PASSWORD"].to_s
    rotate   = %w[true 1 yes].include?(ENV["RECONAUT_ROTATE"].to_s.downcase)

    if password.empty?
      warn "RECONAUT_OPERATOR_PASSWORD required"
      exit 64 # EX_USAGE
    end

    email = Reconaut::Auth::Bootstrap::DEFAULT_OPERATOR_EMAIL if email.empty?

    begin
      result = Reconaut::Auth::Bootstrap.call(
        email:    email,
        password: password,
        rotate:   rotate
      )
    rescue Reconaut::Auth::Bootstrap::AlreadyInitializedError => e
      warn "bootstrap-already-initialized: #{e.message}"
      warn "Ajoutez RECONAUT_ROTATE=true pour roter le password " \
           "(révoque toutes les clés API existantes)."
      exit 65 # EX_DATAERR
    end

    payload = {
      user:    result[:user].to_h,
      api_key: result[:api_key],
      rotated: result[:rotated]
    }
    puts JSON.pretty_generate(payload)
    warn "WARNING: l'API key affichee ci-dessus n'est plus consultable. " \
         "Stockez-la maintenant, sinon il faudra en generer une autre."
  end

  # Alias retro-compat : bootstrap_owner reste utilisable et delegue
  # au nouveau set_password en mappant les anciennes variables d'env.
  desc "[deprecated] Alias de set_password. Utilise les nouvelles variables " \
       "RECONAUT_OPERATOR_EMAIL et RECONAUT_OPERATOR_PASSWORD."
  task bootstrap_owner: :environment do
    require "reconaut/auth/bootstrap"

    email    = (ENV["RECONAUT_OPERATOR_EMAIL"] || ENV["RECONAUT_BOOTSTRAP_OWNER_EMAIL"]).to_s.strip
    password = (ENV["RECONAUT_OPERATOR_PASSWORD"] || ENV["RECONAUT_BOOTSTRAP_OWNER_PASSWORD"]).to_s

    if password.empty?
      warn "RECONAUT_OPERATOR_PASSWORD (or legacy RECONAUT_BOOTSTRAP_OWNER_PASSWORD) required"
      exit 64 # EX_USAGE
    end

    begin
      result = Reconaut::Auth::Bootstrap.call(email: email, password: password)
    rescue Reconaut::Auth::Bootstrap::AlreadyInitializedError => e
      warn "bootstrap-already-initialized: #{e.message}"
      exit 65 # EX_DATAERR
    end

    payload = {
      user:    result[:user].to_h,
      api_key: result[:api_key]
    }
    puts JSON.pretty_generate(payload)
    warn "WARNING: l'API key affichee ci-dessus n'est plus consultable. " \
         "Stockez-la maintenant, sinon il faudra en generer une autre."
  end
end
