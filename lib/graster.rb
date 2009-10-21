#!/usr/bin/env ruby

require 'rubygems'
require 'yaml'
require 'RMagick'

class Graster
  
  autoload :Runner,    File.join(File.dirname(__FILE__), 'graster', 'runner')
  autoload :Image,     File.join(File.dirname(__FILE__), 'graster', 'image')
  autoload :GcodeFile, File.join(File.dirname(__FILE__), 'graster', 'gcode_file')
  autoload :GmaskFile, File.join(File.dirname(__FILE__), 'graster', 'gmask_file')
  
  ROOT2 = Math.sqrt(2)
  
  OPTIONS = {
    :dpi =>             [[Float],"X,Y","Dots per inch of your device"],
    :on_range =>        [[Float],
      "MIN,MAX","Luminosity range for which the",
      "laser should be on"],
    :overshoot =>       [Float,"INCHES",
      "Distance the X axis should travel",
      "past the outer boundaries of the outer",
      "images. This needs to be wide enough",
      "so that the X axis doesn't start",
      "decelerating until after it has",
      "cleared the image"],
    :offset =>          [[Float],"X,Y",
      "Location for the bottom left corner",
      "of the bottom left tile. The X",
      "component of this setting must be",
      "equal to or greater than overshoot"],
    :repeat =>          [[Integer],"X,Y",
      "Number of times to repeat the image",
      "in the X and Y axes, respectively.",
      "Size of the tile(s) inches. Any nil",
      "value is calculated from the size of",
      "the bitmap"],
    :tile_spacing =>    [[Float],"X,Y",
      "X,Y gap between repeated tiles in",
      "inches"],
    :feed =>            [Float,"N",
      "Speed to move the X axis while",
      "burning, in inches/minute"],
    :cut_feed =>        [Float,"N",
      "Speed at which to cut out tiles"],
    :corner_radius =>   [Float,"N",
      "Radius of rounded corners for",
      "cutout, 0 for pointy corners"]
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
