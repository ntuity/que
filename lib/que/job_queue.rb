# frozen_string_literal: true

# A sized thread-safe queue that holds ordered job sort_keys. Supports blocking
# while waiting for a job to become available, only returning jobs over a
# minimum priority, and stopping gracefully.

module Que
  class JobQueue
    # We can only use a binary search on Ruby 2.3+.
    USE_BINARY_SEARCH = [].respond_to?(:bsearch_index)

    attr_reader :maximum_size

    def initialize(maximum_size:)
      @stop         = false
      @array        = []
      @maximum_size = Que.assert(Integer, maximum_size)
      Que.assert(maximum_size > 0)

      @monitor = Monitor.new
      @cv      = Monitor::ConditionVariable.new(@monitor)
    end

    def push(*sort_keys)
      sync do
        # TODO: There's probably a number of sort_keys at which the second
        # method always makes more sense.
        if USE_BINARY_SEARCH
          sort_keys.each do |key|
            i = @array.bsearch_index { |k| compare_keys(key, k) }
            @array.insert(i || -1, key)
          end
        else
          @array.push(*sort_keys).sort_by! do |sort_key|
            sort_key.values_at(:priority, :run_at, :id)
          end
        end

        # Notify all waiting threads that they can try again to remove a item.
        # We could try to only wake up a subset of the waiting threads, to avoid
        # contention when there are many sleeping threads, but not all
        # threads/workers will be interested in all jobs (some have a minimum
        # priority they care about), so how do we notify only the ones with the
        # an appropriate priority threshold? Seems possible, but it would
        # require a custom Monitor/ConditionVariable implementation.
        @cv.broadcast

        # If we passed the maximum queue size, drop the lowest sort keys and
        # return their ids to be unlocked.
        overage = size - maximum_size
        pop_ids(overage) if overage > 0
      end
    end

    # Looping/ConditionVariable technique borrowed from the rubysl-thread gem.
    def shift(priority = Float::INFINITY)
      loop do
        sync do
          if stopping?
            return
          elsif (key = @array.first) && key.fetch(:priority) <= priority
            return @array.shift
          else
            @cv.wait
          end
        end
      end
    end

    def accept?(sort_key)
      sync do
        # Accept the job if there's space available...
        space > 0 ||
        # ...or if it's more important than the lowest item in the queue.
        compare_keys(sort_key, @array.last)
      end
    end

    def space
      sync { maximum_size - size }
    end

    def size
      sync { @array.size }
    end

    def to_a
      sync { @array.dup }
    end

    def stop
      sync { @stop = true; @cv.broadcast }
    end

    def clear
      sync { pop_ids(size) }
    end

    def stopping?
      sync { !!@stop }
    end

    private

    SORT_KEYS = [:priority, :run_at, :id].freeze

    # Given two sort keys a and b, returns true if a < b and false if a > b.
    # Throws an error if they're the same - that shouldn't happen.
    def compare_keys(a, b)
      SORT_KEYS.each do |key|
        a_value = a.fetch(key)
        b_value = b.fetch(key)

        return true  if a_value < b_value
        return false if a_value > b_value
      end

      # Comparing a job's sort key against itself - this shouldn't happen.
      raise Error, "Compared a job's sort key to itself!"
    end

    def pop_ids(count)
      @array.pop(count).map! { |job| job.fetch(:id) }
    end

    def sync(&block)
      @monitor.synchronize(&block)
    end
  end
end
