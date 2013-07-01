module Puppet::Scheduler
  class SplayJob < Job
    attr_reader :splay

    def initialize(run_interval, splay_limit, &block)
      puts "Run interval is #{run_interval}"
      puts "Splay limit is #{splay_limit}"

      @splay = calculate_splay(splay_limit)

      super(run_interval, &block)
    end

    def interval_to_next_from(time)
      puts "Interval to next run from #{time} called."

      # Work out the offset into the current scheduler interval
      # where our next_run falls
      next_run = Time.at((time.to_i / run_interval).to_i * run_interval) + @splay

      # Make sure if our run in this window was in the past (i.e.
      # we've run already) then our next_run is in the next block
      next_run = if next_run <= time
        next_run + run_interval
      else
        next_run
      end

      puts "Next run is at #{next_run}"

      # Now, calculate the interval
      next_run - time
    end


    def ready?(time)
      if last_run
        time > (last_run + interval_to_next_from(last_run))
      else
        time > (start_time + interval_to_next_from(start_time))
      end
    end

    private

    # Private: Calculate the splay given a fixed limit
    #
    # limit - the limit / max-value of the splay
    #
    # Returns an integer that should be (0..limit)
    def calculate_splay(limit)
      Puppet.err("DEBUG: Splay limit is #{limit}")
      rand(limit + 1).tap { |value|
        puts "splay is #{value}"
      }
    end
  end
end
