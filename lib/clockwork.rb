require 'logger'
require 'active_support/time'

require 'clockwork/at'
require 'clockwork/event'
require 'clockwork/manager'

module Clockwork
  class << self
    def included(klass)
      klass.send "include", Methods
      klass.extend Methods
    end

    def manager
      @manager ||= Manager.new
    end

    def manager=(manager)
      @manager = manager
    end
  end

  module Methods
    def configure(&block)
      Clockwork.manager.configure(&block)
    end

    def handler(&block)
      Clockwork.manager.handler(&block)
    end

    def error_handler(&block)
      Clockwork.manager.error_handler(&block)
    end

    def on(event, options={}, &block)
      Clockwork.manager.on(event, options, &block)
    end

    def every(period, job, options={}, user_options={}, &block)
      Clockwork.manager.every(period, job, options, user_options, &block)
    end

    def run
      Clockwork.manager.run
    end

    def clear!
      Clockwork.manager = Manager.new
    end
  end

  extend Methods
end

unless 1.respond_to?(:seconds)
  class Numeric
    def seconds; self; end
    alias :second :seconds

    def minutes; self * 60; end
    alias :minute :minutes

    def hours; self * 3600; end
    alias :hour :hours

    def days; self * 86400; end
    alias :day :days

    def weeks; self * 604800; end
    alias :week :weeks
  end
end
