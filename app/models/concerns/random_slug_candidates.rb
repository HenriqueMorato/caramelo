module RandomSlugCandidates
  extend ActiveSupport::Concern

  included do
    extend FriendlyId
    friendly_id :slug_candidates, use: :slugged
  end

  private

  def slug_candidates
    [ random_slug, random_slug ]
  end

  def random_slug
    "#{self.class::RANDOM_SLUG_PREFIX}-#{SecureRandom.base58(12).downcase}"
  end
end
