#!/usr/bin/env ruby

require 'yaml'

begin
  filename = ARGV[0] or raise
  $width = ARGV[1].to_i
  $height = ARGV[2].to_i
rescue
  puts "convert a raw greyscale bitmap to raster g-code\nusage: ruby raster.rb <bitmap-file> <width> <height>"
  exit 1
end

config = YAML.load_file("graster.yml") or raise "can't find graster.yml"
puts "(#{config.inspect})"

$threshold = config["threshold"].to_i
$zon = config["zon"].to_f
$zoff = config["zoff"].to_f
$step = 1.0/config["dpi"].to_i
$linestep = config["linestep"].to_i
$leftmargin = config["leftmargin"].to_f
$bottommargin = config["bottommargin"].to_f
$feed = config["feed"].to_f
$whitefeed = config["whitefeed"].to_f
$greyscale = config["greyscale"]

def draw_row xorig, yorig, pix, step
  z = false
  yflag = false

  (pix.size+1).times do |i|
    if !z && i < pix.size && pix[i].ord < $threshold
      z = true
      print(if yflag
              "G0"
            else
              yflag = true
              "G0 Y#{yorig}"
            end + " X#{xorig + i*step}\nG1 X#{xorig + (i+1)*step} Z#{$zon}\n")
    elsif z && (i == pix.size || pix[i].ord >= $threshold)
      z = false
      print "G1 X#{xorig + i*step}\nG1 X#{xorig + (i+1)*step} Z#{$zoff}\n"
    end
  end
end

def pix_to_feed pix
  $feed + ($whitefeed - $feed) * (pix.to_f/255.0)**2
end

def draw_greyscale_row xorig, yorig, pix, step, margin
  print "G0 Z#{$zoff} X#{xorig+margin} Y#{yorig}\nG1 X#{xorig-step} F#{$feed}\n"
  pix.size.times do |i|
    print(if i == 0
            "G1 Z#{$zon}"
          elsif i == pix.size-1
            "G1 Z#{$zoff}"
          else
            "G1"
          end + " X#{xorig + i*step} F#{$feed + pix[i].ord.to_f*($whitefeed-$feed)/255.0}\n")
  end
end

File.open(filename,"rb") do |raw|
  print "M3\nG0 Z#{$zoff}\nF#{$feed}\n"
  forward = true

  $height.times do |y|
    row = raw.read($width)
    row.size == $width or raise "premature EOF"

    if y % $linestep == 0
      if forward
        if $greyscale
          draw_greyscale_row $leftmargin, $bottommargin + ($height-y)*$step, row, $step, -$leftmargin/2.0
        else
          draw_row $leftmargin, $bottommargin + ($height-y)*$step, row, $step
        end
        forward = false
      else
        if $greyscale
          draw_greyscale_row $leftmargin + $width*$step, $bottommargin + ($height-y)*$step, row.reverse, -$step, $leftmargin/2.0
        else
          draw_row $leftmargin + $width*$step, $bottommargin + ($height-y)*$step, row.reverse, -$step
        end
        forward = true
      end
      print "\n"
    end
  end

  print "M2\n"
end

