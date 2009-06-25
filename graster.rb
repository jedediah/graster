#!/usr/bin/ruby

require 'yaml'
require 'RMagick'

class Graster
  class Image
    PROPS = [:filename,:size,:pixels]

    def initialize props
      PROPS.each do |p|
        raise "required image property :#{p} missing" unless props[p]
        instance_variable_set "@#{p}", props[p]
      end
    end

    PROPS.each{|p| attr_reader p }

    def self.from_file pathname
      raise "file not found #{pathname}" unless File.exist? pathname
      img = Magick::Image.read(pathname)
      raise "bad image data in #{pathname}" unless img = img[0]
      new :filename => File.basename(pathname),
          :size => [img.columns,img.rows],
          :pixels => img.export_pixels(0,0,img.columns,img.rows,"I")
    end

    # "encode" a float 0..1 to a pixel
    def self.f_to_pix f
      (f*65535).round
    end

    # "decode" an encoded pixel to a float 0..1
    def self.pix_to_f pix
      pix/65535.0
    end

    # get pixel(s) from x,y coords
    # 0,0 is bottom,left
    # image[x,y]    => pixel at x,y
    # image[y]      => row at y
    def [] y, x=nil
      if x
        @pixels[(@size[1]-y)*@size[0]+x]
      else
        @pixels[(@size[1]-y)*@size[0],@size[0]]
      end
    end

    def each_row &block
      @pixels.chars.each_slice(@size[0]).each_with_index &block
    end

    # convert bitmap data to spans (or runs) of contiguous pixels
    # also invert the Y axis
    def build_spans on_range
      @spans = Array.new @size[1]

      @size[1].times do |y|
        spans = []
        left = (@size[1]-y-1)*@size[0]
        start = nil

        @size[0].times do |x|
          d = on_range.include?(@pixels[left+x])

          if !start && d
            start = x
          elsif start && !d
            spans << [start, x]
            start = nil
          end
        end

        spans << [start, @size[0]] if start
        @spans[y] = spans
      end
    end

    attr_reader :spans

    def hash
      [@pixels,@width,@height].hash
    end
  end

  class GcodeFile < File
    def preamble opts
      @laser = false
      self << "M63 P0\nG61\nF#{opts[:feed] || 60}\n"
      self << "M101\n" if opts[:mask]
      self << "M3 S1\n"
    end

    def epilogue
      self << "M63 P0\nM5\nM2\n"
    end

    PRIORITY = [:g,:x,:y,:z,:w,:i,:j,:k,:m,:p,:s]

    def nc codes
      codes = codes.dup

      if codes[:laser] == true && !@laser
        @laser = true
        codes.merge!(:m => 62, :p => 0)
      elsif codes[:laser] == false && @laser
        @laser = false
        codes.merge!(:m => 63, :p => 0)
      end

      codes.delete :laser

      self << codes.sort {|(k1,v1),(k2,v2)|
        PRIORITY.index(k1) <=> PRIORITY.index(k2)
      }.map {|k,v|
        if v.is_a? Integer
          "#{k.upcase}#{v}"
        elsif v.is_a? Float
          "#{k.upcase}%0.3f" % v
        else
          "#{k.upcase}"
        end
      }.join(' ') + "\n"
    end

    def g0 codes
      nc({:g => 0}.merge codes)
    end
    alias_method :jog, :g0

    def g1 codes
      nc({:g => 1}.merge codes)
    end
    alias_method :move, :g1

    def g2 codes
      nc codes.merge(:g => 2)
    end
    alias_method :turn_cw, :g2

    def g3 codes
      nc codes.merge(:g => 3)
    end
    alias_method :turn_ccw, :g3

    def comment txt
      txt = txt.gsub(/\(\)/,'')
      self << "(#{txt})\n"
    end

    def puts *a
      self.puts *a
    end
  end

  class GmaskFile < File
    def preamble
      self << "1 0 0 0\n"
    end

    def begin_row forward
      @begin_row = true
    end

    def span forward, x1, x2
      if forward
        self << "0 0 0 %0.3f\n" % x1 if @begin_row
        self << "0 0 1 %0.3f\n" % x1
        self << "0 1 1 %0.3f\n" % x2
      else
        self << "0 0 1 %0.3f\n" % x1 if @begin_row
        self << "0 0 0 %0.3f\n" % x1
        self << "0 1 0 %0.3f\n" % x2
      end
      @begin_row = false
    end
  end

  ROOT2 = Math.sqrt(2)

  OPTIONS = {
    :dpi =>             [[Float],"X,Y","dots per inch of your device"],
    :on_range =>        [[Float],"MIN,MAX","Luminosity range for which the laser should be on"],
    :overshoot =>       [Float,"INCHES","Distance the X axis should travel past",
                         "the outer boundaries of the outer images",
                         "This needs to be wide enough so that the X axis",
                         "doesn't start decelerating until after it has",
                         "cleared the image"],
    :offset =>          [[Float],"X,Y","location for the bottom left corner of the",
                         "bottom left tile. The X component of this setting",
                         "must be equal to or greater than overshoot"],
    :repeat =>          [[Integer],"X,Y","Number of times to repeat the image in the X and Y axes,",
                         "respectively. Size of the tile(s) inches. Any nil value",
                         "is calculated from the size of the bitmap"],
    :tile_spacing =>    [[Float],"X,Y","X,Y gap between repeated tiles in inches"],
    :feed =>            [Float,"N","Speed to move the X axis while burning, in inches/minute"],
    :cut_feed =>        [Float,"N","Speed at which to cut out tiles"],
    :corner_radius =>   [Float,"N","Radius of rounded corners for cutout, 0 for pointy corners"]
  }

  DEFAULTS = {
    :dpi => [500,500],                 # X,Y dots per inch of your device
    :on_range =>  [0.0,0.5],           # Luminosity range for which the laser should be on
    :overshoot => 0.5,                 # Distance the X axis should travel past the outer boundaries of the outer images.
                                       # This needs to be wide enough so that the X axis doesn't start decelerating
                                       # until after it has cleared the image.
    :offset => [1.0,1.0],              # X,Y location for the bottom left corner of the bottom left tile.
                                       # The X component of this setting must be equal to or greater than :overshoot.
    :repeat => [1,1],                  # Number of times to repeat the image in the X and Y axes, respectively.
    :tile_size => [false,false],       # Size of the tile(s) inches. Any nil value is calculated from
                                       # the size of the bitmap.
    :tile_spacing => [0.125,0.125],    # X,Y gap between repeated tiles in inches
    :feed => 120,                      # Speed to move the X axis while burning, in inches/minute
    :cut_feed => 20,                   # Speed at which to cut out tiles
    :corner_radius => 0                # Radius of rounded corners for cutout, 0 for pointy corners
  }

  class InvalidConfig < Exception; end
  def update_config
    @scale = @config[:dpi].map{|n| 1.0/n }
    @offset = @config[:offset]

    if @image
      2.times {|i| @config[:tile_size][i] ||= @image.size[i]*@scale[i] }
      @tile_interval = 2.times.map {|i|
        @config[:tile_size][i] + @config[:tile_spacing][i]
      }
    end

    @on_range = Range.new Image.f_to_pix(@config[:on_range].first),
                          Image.f_to_pix(@config[:on_range].last)
  end

  def validate_config
    raise InvalidConfig.new "X offset (#{@config[:offset][0]}) must be greater or equal to overshoot (#{@config[:overshoot]})"
  end

  def config= h
    @config = {}
    DEFAULTS.each {|k,v| @config[k] = h[k] || v }
    update_config
    return h
  end

  def merge_config h
    @config ||= DEFAULTS.dup
    h.each {|k,v| @config[k] = v if DEFAULTS[k] }
    update_config
    return h
  end

  attr_reader :config

  def image= img
    debug "image set to #{img.filename} #{img.size.inspect} #{img.pixels.size} pixels"
    @image = img
    @image.build_spans @on_range
    update_config
    build_tiled_rows
    return img
  end

  attr_reader :image

  def try_load_config_file pn
    if File.exist?(pn)
      c = {}
      YAML.load_file(pn).each {|k,v| c[k.intern] = v }
      return c
    end
  end

  def try_load_default_config_file
    try_load_config_file './graster.yml'
  end

  def load_config_file pn
    try_load_config_file pn or raise "config file not found '#{pn}'"
  end

  def load_image_file pn
    self.image = Image.from_file(pn)
  end

  # convert tile + pixel coordinates to inches
  def axis_inches axis, tile, pixel
    @offset[axis] + tile*@tile_interval[axis] + pixel*@scale[axis]
  end

  def x_inches tile, pixel
    axis_inches 0, tile, pixel
  end

  def y_inches tile, pixel
    axis_inches 1, tile, pixel
  end

  # return a complete tiled row of spans converted to inches
  def tiled_row_spans y, forward=true
    spans = @image.spans[y]
    return spans if spans.empty?
    tiled_spans = []

    if forward
      @config[:repeat][0].times do |tile|
        spans.each do |span|
          tiled_spans << [x_inches(tile,span[0]), x_inches(tile,span[1])]
        end
      end
    else
      @config[:repeat][0].times.reverse_each do |tile|
        spans.reverse_each do |span|
          tiled_spans << [x_inches(tile,span[1]), x_inches(tile,span[0])]
        end
      end
    end

    return tiled_spans
  end

  def build_tiled_rows
    forward = false
    @tiled_rows = @image.size[1].times.map {|y| tiled_row_spans y, (forward = !forward) }
  end

  # generate a unique id for this job
  def job_hash
    [@image,@config].hash
  end

  # render a complete tiled image to gcode and gmask streams
  def render_tiled_image gcode, gmask
    debug "rendering tiled image"
    job_id = job_hash
    hyst = -@scale[0]/2
    gcode.comment "raster gcode for job #{job_id}"
    gcode.comment "image: #{@image.filename} #{@image.size.inspect}"
    gcode.comment "config: #{@config.inspect}"

    gcode.preamble :feed => @config[:feed], :mask => true
    gmask.preamble

    @config[:repeat][1].times do |ytile|
      debug "begin tile row #{ytile}"
      @tiled_rows.each_with_index do |spans, ypix|
        debug "pixel row #{ypix} is empty" if spans.empty?
        unless spans.empty?
          yinches = y_inches(ytile, ypix)
          forward = spans[0][0] < spans[-1][1]
          dir = forward ? 1 : -1

          debug "pixel row #{ypix} at #{yinches} inches going #{forward ? 'forward' : 'backward'} with #{spans.size} spans"

          gcode.g0 :x => spans[0][0] - dir*@config[:overshoot], :y => yinches
          gcode.g1 :x => spans[-1][1] + dir*@config[:overshoot], :y => yinches
          gmask.begin_row forward
          spans.each {|span| gmask.span forward, span[0]+hyst, span[1]+hyst }
        end # unless spans.empty?
      end # @image.each_row
      debug "end tile row #{ytile}"
    end # @config[:repeat][i].times

    gcode.epilogue
  end # def render_tiled_image

  # cut out the tile with bottom left at x,y
  def render_cut gcode, x, y
    radius = @config[:corner_radius]
    left = x
    bottom = y
    right = x+@config[:tile_size][0]
    top = y+@config[:tile_size][1]

    gcode.instance_eval do
      if radius && radius > 0
        jog :x => left, :y => bottom+radius
        move :x => left, :y => top-radius, :laser => true
        turn_cw :x => left+radius, :y => top, :i => radius
        move :x => right-radius, :y => top
        turn_cw :x => right, :y => top-radius, :j => -radius
        move :x => right, :y => bottom+radius
        turn_cw :x => right-radius, :y => bottom, :i => -radius
        move :x => left+radius, :y => bottom
        turn_cw :x => left, :y => bottom+radius, :j => radius
        nc :laser => false
      else
        jog :x => left, :y => bottom
        move :x => left, :y => top, :laser => true
        move :x => right, :y => top
        move :x => right, :y => bottom
        move :x => left, :y => bottom
        nc :laser => false
      end
    end
  end

  # render gcode to cut out the tiles
  def render_all_cuts gcode
    gcode.preamble :feed => @config[:cut_feed]
    @config[:repeat][1].times do |ytile|
      @config[:repeat][0].times do |xtile|
        render_cut gcode, x_inches(xtile, 0), y_inches(ytile, 0)
      end
    end
    gcode.epilogue
  end

  def render_all gcode, gmask, cuts
    render_tiled_image gcode, gmask
    render_all_cuts cuts
  end

  def open_gcode_file &block
    io = GcodeFile.open "#{@image.filename}.raster.ngc", "w", &block
  end

  def open_gmask_file &block
    io = GmaskFile.open "#{@image.filename}.raster.gmask", "w", &block
  end

  def open_cut_file &block
    io = GcodeFile.open "#{@image.filename}.cut.ngc", "w", &block
  end

  def generate_all_files
    open_gcode_file do |gcode|
      open_gmask_file do |gmask|
        render_tiled_image gcode, gmask
      end
    end

    open_cut_file do |cut|
      render_all_cuts cut
    end
  end

  def config_to_yaml
    @config.map {|k,v| "#{k}: #{v.inspect}\n" }.join
  end

  def debug msg
    STDERR.puts msg if @debug
  end

  def initialize opts={}
    self.config = DEFAULTS.dup
      
    if opts[:config_file]
      self.merge_config load_config_file opts[:config_file]
    elsif opts[:default_config_file] && c = try_load_default_config_file
      self.merge_config c
    end

    self.merge_config opts[:config] if opts[:config]

    @debug = opts[:debug]

    if opts[:image]
      image = opts[:image]
    elsif opts[:image_file]
      load_image_file opts[:image_file]
    end
  end

end # class Graster

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  require 'optparse'

  options = { :default_config_file => true }
  opts = OptionParser.new do |opts|
    opts.banner = "Usage: graster [options] image"

    opts.on "-c", "--config FILE", "use specified configuration file",
                                   "  default is ./graster.yml" do |c|
      options[:config_file] = c
    end

    opts.on "-g", "--generate", "generate a configuration file with defaults" do
      options[:generate_config] = true
    end

    opts.on "-d", "--debug", "dump useless debug info" do
      options[:debug] = true
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
        options[:config] ||= {}
        if type == Array
          x = x.map {|s| Kernel.send(cast,s) }
        else
          x = Kernel.send(cast,x)
        end

        options[:config][key] = x
      end
    end
  end

  opts.parse! ARGV

  if options[:generate_config]
    print Graster.new(options).config_to_yaml
  else
    unless options[:image_file] = ARGV.shift
      puts opts
      exit 1
    end

    Graster.new(options).generate_all_files
  end
end

