class Spawner
  def initialize *cmd
    @stdin_ext, @stdin = IO.pipe
    @stdout,@stdout_ext = IO.pipe
    @stderr,@stderr_ext = IO.pipe
    @pid = spawn *cmd,
                 STDIN => @stdin_ext,
                 STDOUT => @stdout_ext,
                 STDERR => @stderr_ext
    @stdin_ext.close
    @stdout_ext.close
    @stderr_ext.close
  end

  attr_reader :pid, :stdin, :stdout, :stderr
end

module Graster
  class Motion < Thread
    def initialize
      @streamer = Spawner.new "halstreamer"
      @sampler = Spawner.new "halsampler"
      super {
        @sampler.each_line {|l|
          @beam_enable,
          @x_velocity,
          @y_velocity,
          @x_position_raw,
          @y_position_raw,
          @x_home_switch,
          @y_home_switch,
          @estop_ext = l.split(/\s+/)

          if !@y_home_position
            cmd :yop => 
          elsif !@x_home_position
            
          else
          end
        }
      }
    end # def initialize

    attr_reader :x_velocity, :y_velocity,
                :beam_enable, :estop_ext

    def x_position
      @x_home_position && @x_position_raw - @x_home_position
    end

    def y_position
      @y_home_position && @y_position_raw - @y_home_position
    end

    attr_accessor :x_target, :y_target

    def cmd o
      o = o.dup

      o[:beam] ||= 0

      if o[:xop]
        o[:xop] = case o[:xop] when :lte then 0 when :gt then 1 end
        o[:xbypass] = 0
        o[:xval] ||= 0
      else
        o[:xbypass] = 1
        o[:xval] = 0
      end

      if o[:yop]
        o[:yop] = case o[:yop] when :lte then 0 when :gt then 1 end
        o[:ybypass] = 0
        o[:yval] ||= 0
      else
        o[:ybypass] = 1
        o[:yval] = 0
      end

      @streamer.puts [o[:beam],
                      o[:xvel],o[:xop],o[:xbypass],
                      o[:yvel],o[:yop],o[:ybypass]].join(' ')
    end

  end # class Motion

  class HalSession
    def initialize
      @hal = Spawner.new "halrun -s -f"
      @motion = Motion.new
    end

    def cmd str
      @hal.stdin.puts str
      @hal.stdout.lines.take_while {|l| l.chomp != '%' }
    end
  end
end
