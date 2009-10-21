class Graster
  class Image
    PROPS = [:filename,:size,:pixels]

    def initialize(props)
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

    # get pixel(s) from x,y coords
    # 0,0 is bottom,left
    # image[x,y] => pixel at x,y
    # image[y] => row at y
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

    # "encode" a float 0..1 to a pixel
    def self.f_to_pix f
      (f*65535).round
    end

    # "decode" an encoded pixel to a float 0..1
    def self.pix_to_f pix
      pix/65535.0
    end


    # convert bitmap data to spans (or runs) of contiguous pixels
    # also invert the Y axis
    def build_spans on_range
      # TODO: rewrite in terms of each_row
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
end