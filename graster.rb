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
    if x = slice(i..-1).index(&b)
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

=begin
def draw_row xorig, yorig, pix, param, step, margin
  z = false
  flag = false
  x1 = nil

  #puts "(#{pix.inspect})"
  res = ""

  pix.size.times do |i|
    if !z && draw?(pix[i],param)
      unless flag
        res << "G0 Y#{yorig} X#{xorig+margin}\n"
        flag = true
      end
      z = true
      x1 = xorig + i*step
    elsif z && !draw?(pix[i],param)
      z = false
      res << "G1 #{$laser_off} X#{x1}\nG1 #{$laser_on} X#{xorig + i*step}\n"
    end
  end

  z and res << "G1 #{$laser_off} X#{x1}\nG1 #{$laser_on} X#{xorig + pix.size*step}\n"
  flag and res << "G1 #{$laser_off} X#{xorig + pix.size*step - margin}\n"
  res
end
=end

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
  $raw = image.export_pixels(0,0,$width,$height,"I")
end

read_image $filename

if $greyscale
  raw.uniq.each do |plane|
    File.open("#{$filename}.#{'%02x'%plane}.ngc","w") do |io|
      io.write render($raw,plane)
    end
  end
else
  print render($raw,$threshold)
end
