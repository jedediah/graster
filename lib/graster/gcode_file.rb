class Graster
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
          "#{k.to_s.upcase}#{v}"
        elsif v.is_a? Float
          "#{k.to_s.upcase}%0.3f" % v
        else
          k.to_s.upcase
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
end