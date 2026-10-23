module MarketData
  module ObservationPersistence
    private

    def persist_record(record, attributes:)
      created = record.new_record?
      record.update!(**attributes)
      created ? :created : :updated
    rescue ActiveRecord::RecordNotUnique
      record = yield
      record.update!(**attributes)
      :updated
    end
  end
end
