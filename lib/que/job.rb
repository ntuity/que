# frozen_string_literal: true

# The class that most jobs inherit from.

module Que
  class Job
    attr_reader :que_attrs, :que_error

    def initialize(attrs)
      @que_attrs = attrs
    end

    # Subclasses should define their own run methods, but keep an empty one
    # here so that Que::Job.enqueue can queue an empty job in testing.
    def run(*args)
    end

    def _run
      run(*que_attrs.fetch(:args))
    rescue => error
      @que_error = error
      run_error_notifier = handle_error(error)

      if run_error_notifier && Que.error_notifier
        # Protect the work loop from a failure of the error notifier.
        Que.error_notifier.call(error, que_attrs) rescue nil
      end
    ensure
      finish unless @que_resolved
    end

    private

    def error_count
      que_attrs.fetch(:error_count)
    end

    def handle_error(error)
      error_count    = que_attrs[:error_count] += 1
      retry_interval = self.class.retry_interval || Job.retry_interval

      wait =
        if retry_interval.respond_to?(:call)
          retry_interval.call(error_count)
        else
          retry_interval
        end

      retry_in(wait)
    end

    def retry_in(period)
      Que.execute :set_error, [period, que_error.message, que_attrs.fetch(:id)]
      @que_resolved = true
    end

    def finish
      Que.execute :finish_job, [que_attrs.fetch(:id)]
      @que_resolved = true
    end

    def destroy
      if id = que_attrs[:id]
        Que.execute :destroy_job, [id]
      end
      @que_resolved = true
    end

    @retry_interval = proc { |count| count ** 4 + 3 }

    class << self
      attr_accessor :run_synchronously
      attr_reader :retry_interval

      def enqueue(
        *args,
        queue:     nil,
        priority:  nil,
        run_at:    nil,
        job_class: nil,
        **arg_opts
      )

        args << arg_opts if arg_opts.any?

        attrs = {
          queue:     queue     || resolve_setting(:queue) || Que.default_queue,
          priority:  priority  || resolve_setting(:priority),
          run_at:    run_at    || resolve_setting(:run_at),
          job_class: job_class || to_s,
          args:      args,
        }

        if attrs[:run_at].nil? && resolve_setting(:run_synchronously)
          run(*attrs.fetch(:args))
        else
          values =
            Que.execute(
              :insert_job,
              attrs.values_at(:queue, :priority, :run_at, :job_class, :args),
            ).first

          new(values)
        end
      end

      def run(*args)
        # Make sure things behave the same as they would have with a round-trip
        # to the DB.
        args = Que.json_deserializer.call(Que.json_serializer.call(args))

        # Should not fail if there's no DB connection.
        new(args: args).tap { |job| job.run(*args) }
      end

      def resolve_setting(setting)
        v = instance_variable_get(:"@#{setting}")

        if v.nil?
          c = superclass
          c.resolve_setting(setting) if c.respond_to?(:resolve_setting)
        elsif v.respond_to?(:call)
          v.call
        else
          v
        end
      end
    end
  end
end
