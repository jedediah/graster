#!/usr/bin/env ruby

require 'yaml'
require 'RMagick'

ROOT2 = Math.sqrt(2)

begin
  $filename = ARGV[0] or raise
rescue
  puts "convert a raw greyscale bitmap to raster g-code\nusage: ruby raster.rb <bitmap-file> <width> <height>"
  exit 1
end

$config = YAML.load_file("graster.yml") or raise "can't find graster.yml"

$threshold = $config["threshold"].to_i
$negative = $config["negative"]
$zon = $config["zon"].to_f
$zoff = $config["zoff"].to_f
$power = $config["power"].to_f
$zdelta = ($zoff-$zon).abs
$step = 1.0/$config["dpi"].to_i
$linestep = $config["linestep"].to_i
$leftmargin = $config["leftmargin"].to_f
$bottommargin = $config["bottommargin"].to_f
$feed = $config["feed"].to_f
$whitefeed = $config["whitefeed"].to_f
$greyscale = $config["greyscale"]
$mask = $config["mask"]

$laser_ctl = ["M63 P0","M62 P0"]
# $laser_ctl = ["",""]

### monochrome rastering

def draw? pix, param
  if $greyscale
    pix == param
  elsif $negative
    pix >= $threshold
  else
    pix < $threshold
  end
end

def gx n, params
  res = "G#{n}"
  params.has_key?(:l) and res << " #{$laser_ctl[params[:l]?1:0]}"
  [:x,:y,:z,:w].each {|a| params[a] and res << " #{a.to_s.upcase}%.03f" % params[a] }
  res << "\n"
  res
end

def g1 params; gx 1, params; end
def g0 params; gx 0, params; end

def draw_span x1, x2
  if $mask
    if x1 < x2
      $mask_file.puts "0 0 1 #{x1}"
      $mask_file.puts "0 1 1 #{x2}"
    else
      $mask_file.puts "0 0 0 #{x1}"
      $mask_file.puts "0 1 0 #{x2}"
    end
  end

  g1(:x => x1, :l => false) +
  g1(:x => x2, :l => true)
end

def draw_spans spans, y, margin
  if spans.empty?
    ""
  else
    g0(:y => y, :x => spans.first[0]-margin) +
    spans.map{|span| draw_span(span[0], span[1]) }.join +
    g1(:x => spans.last[1]+margin, :l => false)
  end
end

class Array
  def find_index_after i, &b
    a = slice(i..-1)
    if x = a.find(&b)
      x = a.index(x)
      i + x
    else
      nil
    end
  end
end

def draw_pix xorig, yorig, pix, param, step, margin
  spans = []
  b = 0

  while b < pix.size && a = pix.find_index_after(b) {|p| draw? p, param }
    b = pix.find_index_after(a+1) {|p| !draw? p, param } || pix.size
    spans << [xorig+a*step, xorig+b*step]
  end

   #"(" + spans.map{|s| "#{s[0]}-#{s[1]}"}.join(" ") + ")\n" +
  draw_spans(spans, yorig, margin)
end

def make_spans xorig, pix, param, step
  spans = []
  b = 0

  while b < pix.size && a = pix.find_index_after(b) {|p| draw? p, param }
    b = pix.find_index_after(a+1) {|p| !draw? p, param } || pix.size
    spans << [xorig+a*step, xorig+b*step]
  end

  return spans
end

def render_mask raw, param, gcode, gmask
  gcode.puts "(#{$filename} #{$width} x #{$height})\n(#{$config.inspect})"
  gcode.puts "M63 P0\nG61\nF#{$feed}"
  gcode.puts 'G0 X%0.3f Y%0.3f' % [$leftmargin/2, $bottommargin + $height*$step]
  gcode.puts "M3 S#{$power}"
  gmask.puts "1 0 0 0"
  forward = true

  $height.times do |y|
    row = raw[y*$width...(y+1)*$width]
    yorig = $bottommargin + ($height-y)*$step

    if y % $linestep == 0
      if forward
        spans = make_spans($leftmargin,row,param,$step)
        factor = 1
        xop = 1
      else
        spans = make_spans($leftmargin + $width*$step,row.reverse,param,-$step)
        factor = -1
        xop = 0
      end

      unless spans.empty?
        gcode.puts 'G0 X%0.3f Y%0.3f' % [spans[0][0]-factor*$leftmargin/2, yorig]
        gcode.puts 'G1 X%0.3f' % [spans[-1][1]+factor*$leftmargin/2]

        # wait until we are before the first span, then start the row
        gmask.puts '0 0 %i %0.3f' % [1-xop,spans[0][0]-$step/2]

        spans.each do |s|
          gmask.puts '0 0 %i %0.3f' % [xop,s[0]-$step/2]
          gmask.puts '0 1 %i %0.3f' % [xop,s[1]-$step/2]
        end

        forward = !forward
      end

    end
  end

  gcode.write "M5\nM2\n"
end

def render raw, param
  res = "(#{$filename} #{$width} x #{$height})\n(#{$config.inspect})\nM63 P0\nG64\nF#{$feed}\nM3 S#{$power}\n"
  forward = true

  $height.times do |y|
    row = raw[y*$width...(y+1)*$width]

    if y % $linestep == 0
      if forward
        rowg = draw_pix($leftmargin,
                        $bottommargin + ($height-y)*$step,
                        row,
                        param,
                        $step,
                        $leftmargin/2.0)
      else
        rowg = draw_pix($leftmargin + $width*$step,
                        $bottommargin + ($height-y)*$step,
                        row.reverse,
                        param,
                        -$step,
                        -$leftmargin/2.0)
      end

      #puts "(#{y} #{row[0..20].join ' '})"

      unless rowg.empty?
        res << rowg
        forward = !forward
      end
    end
  end

  res + "M5\nM2\n"
end


### main loop

def read_image filename
  image = Magick::Image.read(filename)
  image = image[0] or raise "unknown image format"
  $width = image.columns # "columns"? WTF??
  $height = image.rows
  $raw = image.export_pixels(0,0,$width,$height,"I").map{|x| x/256 }
end

read_image $filename

if $greyscale
  $raw.uniq.each do |plane|
    File.open("#{$filename}.#{'%02x'%plane}.ngc","w") do |io|
      io.write render($raw,plane)
    end
  end
elsif $mask
  File.open("#{$filename}.gmask", "w") do |mask_file|
    File.open("#{$filename}.ngc", "w") do |gcode_file|
      render_mask $raw, $threshold, gcode_file, mask_file
    end
  end
else
  print render($raw,$threshold)
end
