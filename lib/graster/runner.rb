require 'optparse'

class Graster
  class Runner

    attr_reader :options, :args, :opts
    
    def initialize(args)
      @args = args
      @options = { :default_config_file => true }
      @opts = OptionParser.new do |opts|
        opts.banner = "Usage: graster [options] image"

        opts.on "-c", "--config FILE", "Use specified configuration file.",
                                       "The default is ./graster.yml" do |c|
          @options[:config_file] = c
        end

        opts.on "-g", "--generate", "generate a configuration file with","defaults" do
          @options[:generate_config] = true
        end

        opts.on "-d", "--debug", "Dump useless debug info" do
          @options[:debug] = true
        end

        Graster::OPTIONS.each do |key,info|
          type,sym,*desc = info

          if type.is_a? Array
            cast = type[0].name.intern
            type = Array
          else
            cast = type.name.intern
          end

          opts.on "--#{key.to_s.gsub /_/, '-'} #{sym}", type, *desc do |x|
            @options[:config] ||= {}
            if type == Array
              x = x.map {|s| Kernel.send(cast,s) }
            else
              x = Kernel.send(cast,x)
            end

            @options[:config][key] = x
          end
        end
      end

      @opts.parse!(args)
    end
    
    def start!
      if @options[:generate_config]
        print Graster.new(@options).config_to_yaml
      else
        unless options[:image_file] = args.shift
          puts @opts
          exit 1
        end

        Graster.new(options).generate_all_files
      end
    end
  end
end