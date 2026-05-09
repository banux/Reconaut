# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require "digest"

module Reconaut
  module Embedder
    # LocalEmbedder : zero appel sortant. La v1 livre un encoding
    # deterministe simple base sur SHA-256 des tokens, projete sur la
    # dimension declaree. Suffisant pour exercer le contrat (test
    # contractuel commun aux 4 implementations) et pour des cas demo
    # offline. Le passage a un vrai modele ONNX / llama.cpp est differe
    # (cf. spec : "choix du modele differe").
    #
    # Garanties contractuelles :
    #   - dim de sortie cohérente avec la config (`dim`).
    #   - determinisme batch vs single-item a epsilon pres
    #     (ici epsilon=0 : meme texte -> meme vecteur).
    #   - aucune dependance reseau.
    class Local
      def initialize(dim: Reconaut::Embedder::DEFAULT_LOCAL_DIM)
        raise ArgumentError, "dim must be > 0" unless dim.is_a?(Integer) && dim > 0

        @dim = dim
      end

      attr_reader :dim

      def provider = "local"

      def embed(texts:)
        texts.map { |t| encode(t.to_s) }
      end

      private

      # Encodage deterministe : on hashe le texte, on derive un flux
      # d'octets pseudo-aleatoires reproductibles, puis on normalise vers
      # [-1, 1]. Le texte vide est pris en charge.
      def encode(text)
        seed = Digest::SHA256.digest(text)
        # On etend le seed a `dim` octets via SHA-256 chaine.
        bytes = String.new(encoding: Encoding::BINARY)
        block = seed
        while bytes.bytesize < @dim
          bytes << block
          block = Digest::SHA256.digest(block)
        end
        bytes = bytes.byteslice(0, @dim)
        bytes.bytes.map { |b| (b.to_f - 127.5) / 127.5 }
      end
    end
  end
end
