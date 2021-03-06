# encoding: utf-8

require 'metrics-core-jars'
require 'json'


module Yammer
  module Metrics
    java_import 'com.yammer.metrics.core.MetricsRegistry'
    java_import 'com.yammer.metrics.core.MetricName'
    java_import 'com.yammer.metrics.core.Meter'
    java_import 'com.yammer.metrics.core.Counter'
    java_import 'com.yammer.metrics.core.Histogram'
    java_import 'com.yammer.metrics.core.Gauge'
    java_import 'com.yammer.metrics.core.Timer'
    java_import 'com.yammer.metrics.stats.Snapshot'
    java_import 'com.yammer.metrics.reporting.JmxReporter'

    class Meter
      def type
        :meter
      end

      def to_h
        {
          :type => :meter,
          :event_type => event_type,
          :count => count,
          :mean_rate => mean_rate,
          :one_minute_rate => one_minute_rate,
          :five_minute_rate => five_minute_rate,
          :fifteen_minute_rate => fifteen_minute_rate
        }
      end
    end

    class Counter
      def type
        :counter
      end

      def to_h
        {
          :type => :counter,
          :count => count
        }
      end
    end

    class Histogram
      def type
        :histogram
      end

      def to_h
        {
          :type => :histogram,
          :count => count,
          :max => max,
          :min => min,
          :mean => mean,
          :std_dev => std_dev,
          :sum => sum
        }.merge(snapshot.to_h)
      end
    end

    class Gauge
      def type
        :gauge
      end

      def to_h
        {
          :type => :gauge,
          :value => value
        }
      end
    end

    class Timer
      def type
        :timer
      end

      def to_h
        {
          :type => :timer,
          :event_type => event_type,
          :count => count,
          :mean_rate => mean_rate,
          :one_minute_rate => one_minute_rate,
          :five_minute_rate => five_minute_rate,
          :fifteen_minute_rate => fifteen_minute_rate,
          :max => max,
          :min => min,
          :mean => mean,
          :std_dev => std_dev,
          :sum => sum
        }.merge(snapshot.to_h)
      end

      def measure
        ctx = self.time
        begin
          yield
        ensure
          ctx.stop
        end
      end
    end

    class Snapshot
      def to_h
        {
          :median => median,
          :percentiles => {
            '75'   => get75thPercentile,
            '95'   => get95thPercentile,
            '98'   => get98thPercentile,
            '99'   => get99thPercentile,
            '99.9' => get999thPercentile
          }
        }
      end
    end
  end
end

module JavaConcurrency
  java_import 'java.util.concurrent.TimeUnit'
  java_import 'java.util.concurrent.ConcurrentHashMap'
  java_import 'java.util.concurrent.atomic.AtomicReference'
  java_import 'java.lang.Thread'
end

module Multimeter
  def self.global_registry
    GLOBAL_REGISTRY
  end

  def self.registry(group, scope, instance_id=nil)
    Registry.new(group, scope, instance_id)
  end

  def self.metrics(group, scope, &block)
    Class.new do
      include(Metrics)
      group(group)
      scope(scope)
      instance_eval(&block)
    end.new
  end

  module Metrics
    def self.included(m)
      m.extend(Dsl)
    end

    def initialize(*args)
      super
      self.class.instance_gauges.each do |name, block|
        instance_block = proc { instance_exec(&block) }
        multimeter_registry.gauge(name, &instance_block)
      end
      self.class.instance_metrics.each do |type, name, options|
        multimeter_registry.send(type, name, options)
      end
    end

    def multimeter_registry
      registry_mode = self.class.send(:registry_mode)
      case registry_mode
      when :instance, :linked_instance
        @multimeter_registry ||= begin
          package, _, class_name = self.class.name.rpartition('::')
          group = self.class.send(:group) || package
          scope = self.class.send(:scope) || class_name
          if (iid_proc = self.class.send(:instance_id))
            instance_id = instance_exec(&iid_proc)
          else
            instance_id = self.object_id
          end
          if registry_mode == :linked_instance
            ::Multimeter.global_registry.sub_registry(scope, instance_id)
          else
            ::Multimeter.registry(group, scope, instance_id)
          end
        end
      when :global
        ::Multimeter.global_registry
      else
        self.class.multimeter_registry
      end
    end

    module Dsl
      def multimeter_registry
        @multimeter_registry ||= begin
          package, _, class_name = self.name.rpartition('::')
          g = group || package
          s = scope || class_name
          case registry_mode
          when :linked
            ::Multimeter.global_registry.sub_registry(s)
          when :global
            ::Multimeter.global_registry
          else
            ::Multimeter.registry(g, s)
          end
        end
      end

      def instance_gauges
        @instance_gauges || []
      end

      def instance_metrics
        @instance_metrics || []
      end

      private

      def group(g=nil)
        @multimeter_registry_group = g.to_s if g
        @multimeter_registry_group
      end

      def scope(t=nil)
        @multimeter_registry_scope = t.to_s if t
        @multimeter_registry_scope
      end

      def instance_id(pr=nil, &block_pr)
        pr ||= block_pr
        @multimeter_registry_iid = pr if pr
        @multimeter_registry_iid
      end

      def registry_mode(m=nil)
        @multimeter_registry_mode = m if m
        @multimeter_registry_mode
      end

      def add_instance_gauge(name, block)
        @instance_gauges ||= []
        @instance_gauges << [name, block]
      end

      def add_instance_metric(type, name, options)
        @instance_metrics ||= []
        @instance_metrics << [type, name, options]
      end

      %w[counter meter histogram timer].each do |t|
        type = t.to_sym
        define_method(type) do |name, options={}|
          case registry_mode
          when :instance, :linked_instance
            add_instance_metric(type, name, options)
          else
            multimeter_registry.send(type, name, options)
          end
          define_method(name) do
            multimeter_registry.get(name)
          end
        end
      end

      def gauge(name, &block)
        case registry_mode
        when :instance, :linked_instance
          add_instance_gauge(name, block)
        else
          multimeter_registry.gauge(name, &block)
        end
        define_method(name) do
          multimeter_registry.gauge(name)
        end
      end
    end
  end

  module InstanceMetrics
    def self.included(m)
      m.send(:include, Metrics)
      m.send(:registry_mode, :instance)
    end
  end

  module GlobalMetrics
    def self.included(m)
      m.send(:include, Metrics)
      m.send(:registry_mode, :global)
    end
  end

  module LinkedMetrics
    def self.included(m)
      m.send(:include, Metrics)
      m.send(:registry_mode, :linked)
    end
  end

  module LinkedInstanceMetrics
    def self.included(m)
      m.send(:include, Metrics)
      m.send(:registry_mode, :linked_instance)
    end
  end

  module Jmx
    def jmx!(options={})
      return if @jmx_reporter
      @jmx_reporter = ::Yammer::Metrics::JmxReporter.new(@registry)
      @jmx_reporter.start
      if options[:recursive]
        sub_registries.each do |registry|
          registry.jmx!
        end
      end
    end
  end

  module Http
    def http!(rack_handler, options={})
      return if @server_thread
      @server_thread = JavaConcurrency::Thread.new do
        rack_handler.run(create_app(self), options)
      end
      @server_thread.daemon = true
      @server_thread.name = 'multimeter-http-server'
      @server_thread.start
    end

    private

    class BadRequest < StandardError; end

    COMMON_HEADERS = {'Connection' => 'close'}.freeze
    JSON_HEADERS = COMMON_HEADERS.merge('Content-Type' => 'application/json').freeze
    JSONP_HEADERS = COMMON_HEADERS.merge('Content-Type' => 'application/javascript').freeze
    ERROR_HEADERS = COMMON_HEADERS.merge('Content-Type' => 'text/plain').freeze

    def create_app(registry)
      proc do |env|
        begin
          body = registry.to_h.to_json
          headers = JSON_HEADERS
          if (callback_name = env['QUERY_STRING'][/callback=([^$&]+)/, 1])
            if callback_name =~ /^[\w\d.]+$/
              body = "#{callback_name}(#{body});"
              headers = JSONP_HEADERS
            else
              raise BadRequest
            end
          else
            headers = headers.merge('Access-Control-Allow-Origin' => '*')
          end
          [200, headers, [body]]
        rescue BadRequest => e
          [400, ERROR_HEADERS, ['Bad Request']]
        rescue => e
          [500, ERROR_HEADERS, ["Internal Server Error\n\n", e.message, "\n\t", *e.backtrace.join("\n\t")]]
        end
      end
    end
  end

  class Registry
    include Enumerable
    include Jmx
    include Http

    attr_reader :group, :scope, :instance_id

    def initialize(*args)
      @group, @scope, @instance_id = args
      @registry = ::Yammer::Metrics::MetricsRegistry.new
      @sub_registries = JavaConcurrency::ConcurrentHashMap.new
    end

    def instance_registry?
      !!@instance_id
    end

    def sub_registry(scope, instance_id=nil)
      full_id = scope.dup
      full_id << "/#{instance_id}" if instance_id
      r = @sub_registries.get(full_id)
      unless r
        r = self.class.new(@group, scope, instance_id)
        @sub_registries.put_if_absent(full_id, r)
        r = @sub_registries.get(full_id)
      end
      r
    end

    def sub_registries
      @sub_registries.values.to_a
    end

    def each_metric
      return self unless block_given?
      @registry.all_metrics.each do |metric_name, metric|
        yield metric_name.name, metric
      end
    end
    alias_method :each, :each_metric

    def get(name)
      @registry.all_metrics[create_name(name)]
    end

    def find_metric(name)
      m = get(name)
      unless m
        sub_registries.each do |registry|
          m = registry.find_metric(name)
          break if m
        end
      end
      m
    end

    def gauge(name, options={}, &block)
      existing_gauge = get(name)
      if block_given? && existing_gauge.respond_to?(:same?) && existing_gauge.same?(block)
        return
      elsif existing_gauge && block_given?
        raise ArgumentError, %(Cannot redeclare gauge #{name})
      else
        @registry.new_gauge(create_name(name), ProcGauge.new(block))
      end
    end

    def counter(name, options={})
      error_translation do
        @registry.new_counter(create_name(name))
      end
    end

    def meter(name, options={})
      error_translation do
        event_type = (options[:event_type] || '').to_s
        time_unit = TIME_UNITS[options[:time_unit] || :seconds]
        @registry.new_meter(create_name(name), event_type, time_unit)
      end
    end

    def histogram(name, options={})
      error_translation do
        @registry.new_histogram(create_name(name), !!options[:biased])
      end
    end

    def timer(name, options={})
      error_translation do
        duration_unit = TIME_UNITS[options[:duration_unit] || :milliseconds]
        rate_unit = TIME_UNITS[options[:rate_unit] || :seconds]
        @registry.new_timer(create_name(name), duration_unit, rate_unit)
      end
    end

    def to_h
      h = {@scope => {}}
      each_metric do |metric_name, metric|
        h[@scope][metric_name.to_sym] = metric.to_h
      end
      registries_by_scope = sub_registries.group_by { |r| r.scope }
      registries_by_scope.each do |scope, registries|
        if registries.size == 1
          h.merge!(registries.first.to_h)
        else
          h[scope] = {}
          registries_by_metric = Hash.new { |h, k| h[k] = [] }
          registries.each do |registry|
            registry.each_metric do |metric_name, _|
              registries_by_metric[metric_name] << registry
            end
          end
          registries_by_metric.each do |metric_name, registries|
            if registries.size == 1
              h[scope][metric_name.to_sym] = registries.first.get(metric_name).to_h
            else
              metrics_by_instance_id = Hash[registries.map { |r| [r.instance_id, r.get(metric_name)] }]
              h[scope][metric_name.to_sym] = Aggregate.new(metrics_by_instance_id).to_h
            end
          end
        end
        h
      end
      h.delete_if { |k, v| v.empty? }
      h
    end

    private

    TIME_UNITS = {
      :seconds      => JavaConcurrency::TimeUnit::SECONDS,
      :milliseconds => JavaConcurrency::TimeUnit::MILLISECONDS
    }.freeze

    def create_name(name)
      ::Yammer::Metrics::MetricName.new(@group, @scope, name.to_s)
    end

    def error_translation
      begin
        yield
      rescue java.lang.ClassCastException => cce
        raise ArgumentError, %(Cannot redeclare a metric as another type)
      end
    end
  end

  class Aggregate
    def initialize(metrics)
      @metrics = metrics
      @type = check_type!
    end

    def to_h
      {
        :type => :aggregate,
        :total => compute_total,
        :parts => Hash[@metrics.map { |k, v| [k.to_s, v.to_h] }]
      }
    end

    private

    def check_type!
      types = @metrics.values.map(&:type).uniq
      unless types.size == 1
        raise ArgumentError, %[All metrics of an aggregate must be of the same type (they were: #{types.join(', ')})]
      end
      types.first
    end

    def compute_total
      h = {}
      metric_hs = @metrics.values.map(&:to_h)
      metric_hs.first.keys.each do |property|
        values = metric_hs.map { |h| h[property] }
        aggregate_value = begin
          case property
          when :type, :event_type then values.first
          when :percentiles then nil
          else
            if values.all? { |v| v.nil? || v.is_a?(Numeric) }
              min, max = values.compact.minmax
              sum = values.compact.reduce(:+)
              {
                :max => max,
                :min => min,
                :sum => sum,
                :avg => sum ? sum.fdiv(values.size) : nil,
              }
            end
          end
        end
        h[property] = aggregate_value if aggregate_value
      end
      h
    end
  end

  class ProcGauge < ::Yammer::Metrics::Gauge
    def initialize(proc)
      super()
      @proc = proc
    end

    def value
      @proc.call
    end

    def same?(other_proc)
      other_proc.source_location == @proc.source_location
    end
  end

  GLOBAL_REGISTRY = registry('multimeter', 'global')
end
