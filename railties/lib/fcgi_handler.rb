require 'fcgi'
require 'logger'
require 'dispatcher'
require 'rbconfig'

class RailsFCGIHandler
  SIGNALS = {
    'HUP'  => :reload,
    'TERM' => :graceful_exit,
    'USR1' => :graceful_exit,
    'USR2' => :graceful_restart
  }

  attr_reader :when_ready

  attr_accessor :log_file_path
  attr_accessor :gc_request_period


  # Initialize and run the FastCGI instance, passing arguments through to new.
  def self.process!(*args, &block)
    new(*args, &block).process!
  end

  # Initialize the FastCGI instance with the path to a crash log
  # detailing unhandled exceptions (default RAILS_ROOT/log/fastcgi.crash.log)
  # and the number of requests to process between garbage collection runs
  # (default nil for normal GC behavior.)  Optionally, pass a block which
  # takes this instance as an argument for further configuration.
  def initialize(log_file_path = nil, gc_request_period = nil)
    @when_ready = nil

    self.log_file_path = log_file_path || "#{RAILS_ROOT}/log/fastcgi.crash.log"
    self.gc_request_period = gc_request_period

    # Yield for additional configuration.
    yield self if block_given?

    # Safely install signal handlers.
    install_signal_handlers

    # Start error timestamp at 11 seconds ago.
    @last_error_on = Time.now - 11

    dispatcher_log :info, "starting"
  end

  def process!(provider = FCGI)
    # Make a note of $" so we can safely reload this instance.
    mark!

    # Begin countdown to garbage collection.
    run_gc! if gc_request_period

    provider.each_cgi do |cgi| 
      # Safely reload this instance if requested.
      if when_ready == :reload
        run_gc! if gc_request_period
        restore!
        @when_ready = nil
        dispatcher_log(:info, "reloaded")
      end

      process_request(cgi)

      # Break if graceful exit or restart requested.
      case when_ready
        when :exit
          close_connection(cgi)
          break 
        when :restart
          close_connection(cgi)
          restart!
      end

      # Garbage collection countdown.
      if gc_request_period
        @gc_request_countdown -= 1
        run_gc! if @gc_request_countdown <= 0
      end
    end

    GC.enable
    dispatcher_log :info, "terminated gracefully"

  rescue SystemExit => exit_error
    dispatcher_log :info, "terminated by explicit exit"

  rescue Object => fcgi_error
    # retry on errors that would otherwise have terminated the FCGI process,
    # but only if they occur more than 10 seconds apart.
    if !(SignalException === fcgi_error) && Time.now - @last_error_on > 10
      @last_error_on = Time.now
      dispatcher_error(fcgi_error, "almost killed by this error")
      retry
    else
      dispatcher_error(fcgi_error, "killed by this error")
    end
  end
  
  
  private
    def logger
      @logger ||= Logger.new(@log_file_path)
    end

    def dispatcher_log(level, msg)
      time_str = Time.now.strftime("%d/%b/%Y:%H:%M:%S")
      logger.send(level, "[#{time_str} :: #{$$}] #{msg}")
    rescue Object => log_error
      STDERR << "Couldn't write to #{@log_file_path.inspect}: #{msg}\n"
      STDERR << "  #{log_error.class}: #{log_error.message}\n"
    end

    def dispatcher_error(e, msg = "")
      error_message =
        "Dispatcher failed to catch: #{e} (#{e.class})\n" +
        "  #{e.backtrace.join("\n  ")}\n#{msg}"
      dispatcher_log(:error, error_message)
    end

    def install_signal_handlers
      SIGNALS.each do |signal, handler_name|
        install_signal_handler(signal, method("#{handler_name}_handler").to_proc)
      end
    end

    def install_signal_handler(signal, handler)
      trap(signal, handler)
    rescue ArgumentError
      dispatcher_log :warn, "Ignoring unsupported signal #{signal}."
    end

    def graceful_exit_handler(signal)
      dispatcher_log :info, "asked to terminate ASAP"
      @when_ready = :exit
    end

    def reload_handler(signal)
      dispatcher_log :info, "asked to reload ASAP"
      @when_ready = :reload
    end

    def graceful_restart_handler(signal)
      dispatcher_log :info, "asked to restart ASAP"
      @when_ready = :restart
    end

    def process_request(cgi)
      Dispatcher.dispatch(cgi)
    rescue Object => e
      raise if SignalException === e
      dispatcher_error(e)
    end

    def mark!
      @features = $".clone
    end

    def restore!
      $".replace @features
      Dispatcher.reset_application!
      ActionController::Routing::Routes.reload
    end

    def restart!
      config       = ::Config::CONFIG
      ruby         = File::join(config['bindir'], config['ruby_install_name']) + config['EXEEXT']
      command_line = [ruby, $0, ARGV].flatten.join(' ')
      
      dispatcher_log :info, "restarted"

      exec(command_line)
    end

    def run_gc!
      @gc_request_countdown = gc_request_period
      GC.enable; GC.start; GC.disable
    end
    
    def close_connection(cgi)
       cgi.instance_variable_get("@request").finish
    end
end
