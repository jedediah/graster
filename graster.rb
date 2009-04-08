#!/usr/bin/env ruby

require 'yaml'

ROOT2 = Math.sqrt(2)

begin
  filename = ARGV[0] or raise
  $width = ARGV[1].to_i
  $height = ARGV[2].to_i
rescue
  puts "convert a raw greyscale bitmap to raster g-code\nusage: ruby raster.rb <bitmap-file> <width> <height>"
  exit 1
end

$config = YAML.load_file("graster.yml") or raise "can't find graster.yml"

$threshold = $config["threshold"].to_i
$negative = $config["negative"]
$zon = $config["zon"].to_f
$zoff = $config["zoff"].to_f
$zdelta = ($zoff-$zon).abs
$step = 1.0/$config["dpi"].to_i
$linestep = $config["linestep"].to_i
$leftmargin = $config["leftmargin"].to_f
$bottommargin = $config["bottommargin"].to_f
$feed = $config["feed"].to_f
$whitefeed = $config["whitefeed"].to_f
$greyscale = $config["greyscale"]


### monochrome rastering

def draw_span x1, x2
  if x1 < x2
    "G0 X#{x1}\n" +
    "G1 X#{x1+$zdelta} Z#{$zon} F#{$feed*ROOT2}\n" +
    "G1 X#{x2} F#{$feed}\n" +
    "G1 X#{x2+$zdelta} Z#{$zoff} F#{$feed*ROOT2}\n"
  else
    "G0 X#{x1+$zdelta}\n" +
    "G1 X#{x1} Z#{$zon} F#{$feed*ROOT2}\n" +
    "G1 X#{x2+$zdelta} F#{$feed}\n" +
    "G1 X#{x2} Z#{$zoff} F#{$feed*ROOT2}\n"
  end
end

def draw? pix, param
  if $greyscale
    pix == param
  elsif $negative
    pix > $threshold
  else
    pix < $threshold
  end
end

def draw_row xorig, yorig, pix, param, step, margin
  z = false
  x1 = nil

  #puts "(#{pix.inspect})"
  res = "G0 Y#{yorig} X#{xorig+margin}\n"

  pix.size.times do |i|
    if !z && draw?(pix[i],param)
      z = true
      x1 = xorig + i*step
    elsif z && !draw?(pix[i],param)
      z = false
      res << draw_span(x1, xorig + i*step)
    end
  end

  z and res << draw_span(x1, xorig + pix.size*step)
  res
end


def render raw, param
  res = "(#{$config.inspect})\nM3\nG0 Z#{$zoff}\nF#{$feed}\n"
  forward = true

  $height.times do |y|
    row = raw[y*$width...(y+1)*$width]

    if y % $linestep == 0
      if forward
        res += draw_row($leftmargin,
                        $bottommargin + ($height-y)*$step,
                        row,
                        param,
                        $step,
                        -$leftmargin/2.0)
        forward = false
      else
        res += draw_row($leftmargin + $width*$step,
                        $bottommargin + ($height-y)*$step,
                        row.reverse,
                        param,
                        -$step,
                        $leftmargin/2.0)
        forward = true
      end
      res << "\n"
    end
  end

  res + "M2\n"
end


### main loop

raw = File.open(filename,"rb") {|io| io.bytes.to_a }
raw.size == $width*$height or raise "file size does not match image dimensions"

if $greyscale
  raw.uniq.each do |plane|
    File.open("#{filename}.#{'%02x'%plane}.ngc","w") do |io|
      io.write render(raw,plane)
    end
  end
else
  print render(raw,$threshold)
end
