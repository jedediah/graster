class Graster
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
end