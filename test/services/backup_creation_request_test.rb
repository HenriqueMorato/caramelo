require "test_helper"

class BackupCreationRequestTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  teardown do
    Backup::CreationRequest.release
    Rails.cache.clear
  end

  test "queues a due backup once" do
    creator = Class.new do
      def self.due? = true
    end
    job = Class.new do
      class << self
        attr_accessor :queued
        def perform_later = self.queued = true
      end
    end
    state = Class.new do
      class << self
        attr_accessor :queued
        def queued! = self.queued = true
      end
    end

    assert_equal :queued, Backup::CreationRequest.call(creator:, job:, state:)
    assert job.queued
    assert state.queued
    assert_equal :already_queued, Backup::CreationRequest.call(creator:, job:, state:)
  end

  test "skips a backup that is not due" do
    creator = Class.new do
      def self.due? = false
    end

    assert_equal :not_due, Backup::CreationRequest.call(creator:)
  end

  test "releases a claim when queueing fails" do
    creator = Class.new do
      def self.due? = true
    end
    job = Class.new do
      def self.perform_later = raise("queue unavailable")
    end
    state = Class.new do
      def self.queued! = true
    end

    assert_raises(RuntimeError) { Backup::CreationRequest.call(creator:, job:, state:) }
    refute Rails.cache.exist?(Backup::CreationRequest::CLAIM_KEY)
  end
end
