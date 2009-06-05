require 'set'

class Module
  def define_module_method meth, &block
    define_singleton_method meth, &block
    define_method(meth) {|*args, &block| self.class.send meth, *args, &block }
  end
end

module HAL
  module Mungers
    def hyphenize id
      id.to_s.gsub(/_|\./,'-')
    end

    def dehyphenize id
      id.to_sgsub(/-/,'_').intern
    end

    def camelize id
      id.to_s.sub(/^[a-z]/){|m| m.upcase}.gsub(/_([A-Za-z0-9])/){ $1[0].upcase + $1[1..-1] }.intern
    end

    def decamelize id
      id.to_s.sub(/^[A-Z]/) {|m| m.downcase}.
        gsub(/[A-Z]/) {|m| "_#{m.downcase}" }
    end
  end

  class Builder
    include Mungers

    def initialize options={}, &block
      @options = options
      @components = {}
      @threads = {}
      instance_eval &block if block
    end

    def trace str
      STDERR.puts ">>> #{str}" if @options[:trace]
    end

    def component_type_class_name type
      camelize(type)
    end

    def component_type_defined? type
      Component.const_defined? component_type_class_name(type)
    end

    def component_type_class type
      cname = component_type_class_name(type)
      raise "unknown component type #{type}" unless Component.const_defined?(cname)
      Component.const_get(cname)
    end

    def component_type_count type
      trace "counting components: #{@components.inspect}"
      @components.count {|k,v| v.hal_type == type }
    end

    def components_by_type
      @components.reduce({}) do |h,(label,comp)|
        h[comp.class] ||= {}
        h[comp.class][label] = comp
        h
      end
    end

    def component_defined? label
      @components.has_key? label
    end

    def component label
      @components[label]
    end

    def loadrt type, label, options={}, &block
      ordinal = component_type_count(type)
      klass = component_type_class(type)

      label ||= if klass.singleton?
                  type
                else
                  "#{type}_#{ordinal}".intern
                end

      trace "loadrt #{type}, #{label}, #{options.inspect}"
      @components[label] = component_type_class(type).new(self, ordinal, label, options)

      if block
        trace "evaluating component block for #{label}"
        @components[label].instance_eval &block
      else
        trace "no block for component #{label}"
        @components[label]
      end
    end

    def thread id, opts, &block
      raise "period required for thread #{id}" unless opts[:period]
      
      trace "thread #{id}, #{opts.inspect}"

      opts[:float] ||= true
      @threads[id] = thread = HAL::Thread.new(self, id, opts)
      thread.instance_eval(block)
    end

    def method_missing meth, *args, &block
      trace "method_missing #{meth}, #{args.inspect}, #{block}"

      if @components.has_key?(meth)
        trace "resolve component #{meth}"
        if block
          @components[meth].instance_eval &block
        else
          @components[meth]
        end
      elsif component_type_defined?(meth)
        trace "resolve component type #{meth}"
        label,options = if args[0].is_a? Symbol
                          [args[0],args[1] || {}]
                        else
                          [nil,args[0] || {}]
                        end

        loadrt meth, label, options, &block
      else
        super
      end
    end

    def hal_code
      str = ''

      cbt = components_by_type
      cbt.each_pair do |klass,instances|
        str << "\n\n### #{klass.hal_type} components ###\n"
        str << klass.hal_loadrt(instances.values)
        str << instances.values.map {|c| c.hal_code }.join("\n")
      end

      str << "\n\n### threads ###\n"
      str << HAL::Thread.hal_loadrt(@threads.values)
      str << @threads.values.map {|t| t.hal_code }.join("\n")

      str << "\n\n### HAL start ###\nstart\n"
    end

    module Grammar
      class Context

        class << self
          def rule name, pat, &block
            raise ArgumentError.new "block required" unless block
            @rules ||= []
            @rules << [pat,block]
          end

          def rules; @rules || []; end
        end # class << self

        def method_missing meth, *args, &block
          rules.each do |pat|
            catch :fail do
              if pat[0].is_a?(Symbol) && meth == pat[0]
                return pat[1].call *args, &block
              elsif pat[0].is_a?(Regexp) && meth =~ pat[0]
                return pat[1].call meth, *args, &block
              end
            end
          end
          super
        end # def method_missing

      end # class Context

      class Primary < Context
        rule 
      end

      class Component
        def initialize label
          @label = label
          @type = nil
          @options = {}
          @params = {}
        end

        attr_accessor :label, :type, :options, :params
      end

      class Pin
        include Mungers

        def initialize component, *path
          @component = component
          @path = path
        end
        attr_reader :component
        attr_reader :path

        def method_missing meth, *args, &block
          self.class.new @component, [*@path,meth]
        end

        def pin_defined?
          false
        end

        def validate
          raise "unknown pin reference #{hal_pin}" unless pin_defined?
        end

        def hal_pin
          [@component.hal_instance,*path.map{|p| hyphenize(p) }].join('.')
        end
      end

      class OutputPin < Pin
        def pin_defined?
          @component.output_defined? @path
        end
      end

      class InputPin
        def pin_defined?
          @component.input_defined? @path
        end

        def <= value
          @component.assign_input self, value
        end
      end

    end # module Grammar
  end # class Builder


  class Thread
    def initialize context, id, opts
      @context = context
      @id = id
      @period = opts[:period]
      @float = opts[:float] || false
      @calls = []
    end

    attr_reader :period

    def method_missing meth
      if @context.component_defined? meth
        call = FunctionCall.new(self, @context.component(meth))
        @calls << call
        return call
      else
        super
      end
    end

    def hal_id
      hyphenize @id
    end

    def self.hal_loadrt instances
      if instances.empty?
        ''
      else
        "loadrt threads " +
          instances.each_with_index.
          map {|th,i| "name#{i+1}=\"#{th.hal_id}\" period#{i+1}=#{th.period}"}.
          join(", ") + "\n"
      end
    end

    def hal_calls
      @calls.map {|x| x.hal_code }.join
    end

    def hal_comment
      "# thread #{hal_id}\n"
    end

    def hal_code
      hal_comment +
      hal_calls
    end

    class FunctionCall
      def initialize thread, component, function=nil
        @thread = thread
        @component = component
        @function = function
      end

      attr_reader :component
      attr_reader :function

      def method_missing meth
        @component.validate_function meth
        @function = meth
      end

      def hal_code
        "addf #{@component.hal_function @function} #{@thread.hal_id}\n"
      end
    end # class FunctionCall

  end # class Thread

  class Component

    include Mungers

    ASPECTS = [:option,:input,:output,:param,:function]

    class << self
      include Mungers

      def trace str
        # puts ">>> #{basename}: #{str}"
      end

      def inherited klass
        trace "define component #{klass.basename}"
        klass.instance_eval do
          @def = {}
          ASPECTS.each {|asp| @def[asp] = [] }
        end
      end

      def singleton x=true
        @singleton = !!x
      end

      def hal_loadrt_params instances
        str = ''
        @def[:option].each do |o|
          if instances.any? {|i| i.options.has_key? o }
            raise "option #{o} not specified for all components" unless
              instances.all? {|i| i.options.has_key? o }
            "#{o}=" + instances.map {|i| i.options[o].inspect }.join(',')
          end
        end.join(' ')
      end

      def hal_loadrt instances
        trace "generate loadrt instances=#{instances.inspect}"
        if instances.empty?
          ''
        else
          if singleton?
            raise "multiple instances of singleton component #{hal_type}" unless
              instances.size == 1
            "loadrt #{hal_type} #{hal_loadrt_params instances}\n"
          else
            "loadrt #{hal_type} count=#{instances.size} #{hal_loadrt_params instances}\n"
          end
        end          
      end

    end # class << self

    ASPECTS.each do |asp|
      trace "define aspect #{asp}"
      define_module_method "def_#{asp}s" do |*args|
        trace "def_#{asp}s #{args.inspect}"
        @def[asp] = args
      end

      define_module_method "#{asp}_defined?" do |id|
        @def[asp].include? id
      end

      define_module_method "validate_#{asp}" do |id|
        raise "unknown #{asp} #{hal_type}.#{id}" unless @def[asp].include? id
      end
    end

    define_module_method :hal_type do
      decamelize self.basename
    end

    define_module_method :singleton? do
      @singleton
    end

    def initialize context, index, label, options={}
      options.keys.each {|k| validate_option k }

      @context = context
      @index = index
      @label = label
      @options = options
      @inputs = {}
      @outputs = []
      @params = {}
    end

    attr_reader :options
    attr_reader :params

    def trace str
      @context.trace "#{hal_instance} (#{hal_label}): #{str}"
    end

    def assign_input pin, value
      trace "assigning #{value} to input #{pin.hal_pin}"
      raise "invalid input pin value #{value.inspect}" unless
        value.is_a?(Numeric) ||
        (value.is_a?(Array) &&
         value[0].is_a?(Component) &&
         value[1].is_a?(OutputPinReference) &&
         value[1].pin_defined?)
          
      @inputs[pin] = value
    end

    def method_missing meth, *args, &block
      trace "resolving within component: #{meth.inspect}, #{args.inspect}, #{block}"

      if param_defined? meth
        trace "setting parameter #{meth} to #{args[0].inspect}"
        raise "expected value after parameter #{meth}" unless args[0]
        @params[meth] = args[0]
      elsif input_defined? meth
        trace "referencing input #{meth}"
        return InputPinReference.new self, meth
      elsif output_defined? meth
        trace "referencing output #{meth}"
        return OutputPinReference.new self, meth
      else
        trace "falling through to builder context"
        @context.send meth, *args, &block
      end
    end

    def hal_label
      hyphenize(@label)
    end

    def hal_instance
      if singleton?
        hyphenize hal_type
      else
        "#{hyphenize hal_type}.#{@index}"
      end
    end

    def hal_pin id
      "#{hal_instance}.#{hyphenize(id)}"
    end

    # signals are named after the output connected to them
    # with the form label-pin
    def hal_signal pin
      validate_output pin
      "#{hal_label}-#{hyphenize(pin)}"
    end

    def hal_constant_signal value
      "signal-#{value.to_s.gsub(/\./,'-')}"
    end

    def hal_output_net pin
      validate_output pin
      "net #{hal_signal pin} <= #{hal_pin pin}\n"
    end

    def hal_input_net id
      validate_input id
      inp = @inputs[id]
      if inp.is_a? Numeric
        "net #{hal_constant_signal inp} => #{hal_pin id}\n"
        "sets #{hal_constant_signal inp} #{inp}\n"
      else
        src_inst = @inputs[id][0]
        src_pin = @inputs[id][1]
        "net #{src_inst.hal_signal src_pin} => #{hal_pin id}\n"
      end
    end

    def hal_param id
      validate_param id
      "setp #{hal_instance}.#{hyphenize(id)} #{@params[id]}\n"
    end

    def hal_output_nets
      @outputs.map {|o| hal_output_net o }.join
    end

    def hal_input_nets
      @inputs.keys.map {|i| hal_input_net i }.join
    end

    def hal_params
      @params.keys.map {|p| hal_param p }.join
    end

    def hal_function id=nil
      if id.nil?
        hal_instance
      else
        validate_function id
        "#{hal_instance}.#{hyphenize(id)}"
      end
    end

    def hal_comment
      if singleton?
        "\n# #{hal_label}\n"
      else
        "\n# #{hal_instance}: #{hal_label}\n"
      end
    end

    def hal_code
      trace "hal_code #{hal_label}"
      if @params.empty? && @inputs.empty? && @outputs.empty?
        ''
      else
        hal_comment +
        hal_params +
        hal_output_nets +
        hal_input_nets
      end
    end

    def inspect
      "#<#{self.class.name}:#{object_id.to_s(16)} #{hal_instance}:#{hal_label}>"
    end

    class And2 < Component
      def_inputs :in0, :in1
      def_outputs :out
    end # class And

    class Or2 < Component
      def_inputs :in0, :in1
      def_outputs :out
    end # class Or

    class Comp < Component
      def_params :hyst
      def_inputs :in0, :in1
      def_outputs :out, :equal
    end # class Comp

    class Stepgen < Component
      def_options :step_type
      def_params :position_scale,
                 :steplen,
                 :stepspace,
                 :dirhold,
                 :dirsetup,
                 :maxaccel,
                 :enable
      def_inputs :position_cmd
      def_outputs :position_fb, :dir, :step
    end # class Stepgen

    class Streamer < Component
      def_options :depth, :cfg
      def_inputs :enable
      def_outputs *(0..63).map{|n| "pin_#{n}".intern }
    end # class Streamer

    class Parport < Component
      def_options :address, :direction
      def_params :reset_time, *(0..17).map{|n| "pin_#{n}_out_reset".intern }
      def_inputs *(0..17).map{|n| "pin_#{n}_out".intern }

      def self.hal_loadrt instances
        instances.each {|i| raise "parport #{i.hal_label} missing required address option" unless i.options[:address]}
        "loadrt probe_parport\n" +
        "loadrt hal_parport cfg=\"" +
        instances.map {|i| "0x#{i.options[:address].to_s(16)}" +
                           (i.options[:direction] ? " #{i.options[:direction]}" : '') }.join(' ') +
        "\""
      end
    end

    class ChargePump < Component
      singleton
      def_params :enable
      def_outputs :out
    end

  end # class Component
end # module HAL

=begin
def make_it
  hal = HAL::Builder.new(:trace => true) do
    or2 :lenny do
    end

    and2 :brucy do
      in0 <= lenny.out
      in1 <= 1
    end
  end

  print hal.hal_code
end


make_it

=end
