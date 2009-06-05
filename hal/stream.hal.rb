load "./halgen.rb"

print HAL::Builder.new(:trace => false) {

  charge_pump do
    enable 1
  end

  parport :address => 0x378 do
    reset_time 100000
    pin_17_out_reset 1
    pin_17_out <= charge_pump.out
    pin_14_out <= 1
  end

  streamer :instream, :depth => 256, :cfg => "bfbffbf"  do
    
  end

  stepgen :step_x, :step_type => 0 do
    position_scale 500
    steplen 50000
    stepspace 50000
    dirhold 50000
    dirsetup 50000
    maxaccel 30
    enable 1
    position_cmd <= instream.pin.1
  end

}.hal_code
