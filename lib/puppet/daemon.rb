require 'puppet'
require 'puppet/util/pidlock'
require 'puppet/application'

# A module that handles operations common to all daemons.  This is included
# into the Server and Client base classes.
class Puppet::Daemon
  attr_accessor :agent, :server, :argv

  def daemonname
    Puppet[:name]
  end

  # Put the daemon into the background.
  def daemonize
    if pid = fork
      Process.detach(pid)
      exit(0)
    end

    create_pidfile

    # Get rid of console logging
    Puppet::Util::Log.close(:console)

    Process.setsid
    Dir.chdir("/")
    begin
      $stdin.reopen "/dev/null"
      $stdout.reopen "/dev/null", "a"
      $stderr.reopen $stdout
      Puppet::Util::Log.reopen
    rescue => detail
      Puppet.err "Could not start #{Puppet[:name]}: #{detail}"
      Puppet::Util::replace_file("/tmp/daemonout", 0644) do |f|
        f.puts "Could not start #{Puppet[:name]}: #{detail}"
      end
      exit(12)
    end
  end

  # Create a pidfile for our daemon, so we can be stopped and others
  # don't try to start.
  def create_pidfile
    Puppet::Util.synchronize_on(Puppet[:name],Sync::EX) do
      raise "Could not create PID file: #{pidfile}" unless Puppet::Util::Pidlock.new(pidfile).lock
    end
  end

  # Provide the path to our pidfile.
  def pidfile
    Puppet[:pidfile]
  end

  def reexec
    raise Puppet::DevError, "Cannot reexec unless ARGV arguments are set" unless argv
    command = $0 + " " + argv.join(" ")
    Puppet.notice "Restarting with '#{command}'"
    stop(:exit => false)
    exec(command)
  end

  def reload
    return unless agent
    if agent.running?
      Puppet.notice "Not triggering already-running agent"
      return
    end

    agent.run
  end

  # Remove the pid file for our daemon.
  def remove_pidfile
    Puppet::Util.synchronize_on(Puppet[:name],Sync::EX) do
      Puppet::Util::Pidlock.new(pidfile).unlock
    end
  end

  def restart
    Puppet::Application.restart!
    reexec unless agent and agent.running?
  end

  def reopen_logs
    Puppet::Util::Log.reopen
  end

  # Trap a couple of the main signals.  This should probably be handled
  # in a way that anyone else can register callbacks for traps, but, eh.
  def set_signal_traps
    signals = {:INT => :stop, :TERM => :stop }
    # extended signals not supported under windows
    signals.update({:HUP => :restart, :USR1 => :reload, :USR2 => :reopen_logs }) unless Puppet.features.microsoft_windows?
    signals.each do |signal, method|
      Signal.trap(signal) do
        Puppet.notice "Caught #{signal}; calling #{method}"
        send(method)
      end
    end
  end

  # Stop everything
  def stop(args = {:exit => true})
    Puppet::Application.stop!

    server.stop if server

    remove_pidfile

    Puppet::Util::Log.close_all

    exit if args[:exit]
  end

  def start
    set_signal_traps

    create_pidfile

    raise Puppet::DevError, "Daemons must have an agent, server, or both" unless agent or server

    # Start the listening server, if required.
    server.start if server

    # Finally, loop forever running events - or, at least, until we exit.
    run_event_loop
  end

  #### Modified Event Loop Code by Thomas Haggett ####
  ####           thomas@freeagent.com             ####
  # Public: Return the next event time based on a given interval.
  #
  #   interval    - the time interval of this event (in seconds)
  #   splay       - if true, a host-consistent offset is added to the time
  #
  # Returns Time object
  def next_event_time(interval, splay=false)
    offset = if splay
      Digest::MD5.hexdigest(Facter[:fqdn].value).to_i(16) % interval
    else
      0
    end

    next_run = Time.at((Time.now.to_i / interval).to_i * interval) + offset
    if next_run <= Time.now
      next_run + interval
    else
      next_run
    end
  end

  # Private: Dispatches the events of different types
  def dispatch_event(event)
    case event
    when :agent
      agent.run
    when :reparse
      Puppet.settings.reparse
    end
  end

  # Private: Emits a hash of events to monitor
  # 
  # Returns a hash { :events => { key => interval }, :splay => [ key, key2 ] }
  def configure_events
    {
      :events => {
        :tick => 3600,
        :agent => Puppet[:runinterval]
      },
      :splay => [:agent]
    }.tap do |output|
      reparse_interval = Puppet[:filetimeout].to_i
      output[:events][:reparse] = reparse_interval if reparse_interval > 0
    end
  end

  def run_event_loop

    # This maintains a dictionary of timestamps keyed against the event names
    times = {}
    events = {}

    loop do
      # we configure the events on each run to cope with configuration reloads and
      # the like
      config = configure_events

      # re-generate any missing times
      config[:events].each_pair do |key,interval|
        unless times[key]
          times[key] = next_event_time(interval, config[:splay].include?(key)) 
          Puppet.notice("Next #{key} run will be at #{times[key]}")
        end
      end

      # Pick out the earliest timestamp of the set
      next_event_time = times.values.min || (Time.now + 30) 

      # if it's in the future, sleep until now is then...
      sleep_interval = if next_event_time > Time.now
        next_event_time.to_f - Time.now.to_f
      else
        # Always sleep for a second, just to avoid accidental tight loops!
        1
      end  
      select([], [], [], sleep_interval)

      # Now, lets go through our event set and run any who's time-stamp is leq Time.now()
      #
      # IT's worth noting that, if the event execution steps over another event's timestamp, then the loop
      # will recycle and we just won't sleep the next time around.
      #
      times.each_pair do |key,timestamp|
        if timestamp < Time.now
          times[key] = nil
          dispatch_event(key)
        end
      end
    end
  end

end
