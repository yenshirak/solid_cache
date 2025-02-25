# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"

module SolidCache
  class Cluster
    module Expiry
      # For every write that we do, we attempt to delete EXPIRY_MULTIPLIER times as many records.
      # This ensures there is downward pressure on the cache size while there is valid data to delete
      EXPIRY_MULTIPLIER = 1.25

      attr_reader :expiry_batch_size, :expiry_method, :expiry_queue, :expires_per_write, :max_age, :max_entries

      def initialize(options = {})
        super(options)
        @expiry_batch_size = options.fetch(:expiry_batch_size, 100)
        @expiry_method = options.fetch(:expiry_method, :thread)
        @expiry_queue = options.fetch(:expiry_queue, :default)
        @expires_per_write = (1 / expiry_batch_size.to_f) * EXPIRY_MULTIPLIER
        @max_age = options.fetch(:max_age, 2.weeks.to_i)
        @max_entries = options.fetch(:max_entries, nil)

        raise ArgumentError, "Expiry method must be one of `:thread` or `:job`" unless [ :thread, :job ].include?(expiry_method)
      end

      def track_writes(count)
        expiry_batches(count).times { expire_later }
      end

      private
        def expiry_batches(count)
          batches = (count * expires_per_write).floor
          overflow_batch_chance = count * expires_per_write - batches
          batches += 1 if rand < overflow_batch_chance
          batches
        end

        def expire_later
          if expiry_method == :job
            ExpiryJob
              .set(queue: expiry_queue)
              .perform_later(expiry_batch_size, shard: Entry.current_shard, max_age: max_age, max_entries: max_entries)
          else
            async { Entry.expire(expiry_batch_size, max_age: max_age, max_entries: max_entries) }
          end
        end
    end
  end
end
