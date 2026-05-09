# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

# Classe de base pour tous les modèles ActiveRecord.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
