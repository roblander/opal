require File.expand_path('../../spec_helper', __FILE__)
require File.expand_path('../fixtures/return', __FILE__)

describe "The return keyword" do
  it "returns any object directly" do
    def r; return 1; end
    r().should == 1
  end

  it "returns an single element array directly" do
    def r; return [1]; end
    r().should == [1]
  end

  it "returns an multi element array directly" do
    def r; return [1,2]; end
    r().should == [1,2]
  end

  it "returns nil by default" do
    def r; return; end
    r().should be_nil
  end

  describe "in a Thread" do
    ruby_version_is "" ... "1.9" do
      it "raises a ThreadError if used to exit a thread" do
        lambda { Thread.new { return }.join }.should raise_error(ThreadError)
      end
    end

    ruby_version_is "1.9" do
      pending "raises a LocalJumpError if used to exit a thread" do
        lambda { Thread.new { return }.join }.should raise_error(LocalJumpError)
      end
    end
  end

  describe "when passed a splat" do
    ruby_version_is "" ... "1.9" do
      it "returns nil when the ary is empty" do
        def r; ary = []; return *ary; end
        r.should be_nil
      end
    end

    ruby_version_is "1.9" do
      pending "returns [] when the ary is empty" do
        def r; ary = []; return *ary; end
        r.should == []
      end
    end

    ruby_version_is "" ... "1.9" do
      it "returns the first element when the array is size of 1" do
        def r; ary = [1]; return *ary; end
        r.should == 1
      end
    end

    ruby_version_is "1.9" do
      it "returns the array when the array is size of 1" do
        def r; ary = [1]; return *ary; end
        r.should == [1]
      end
    end

    it "returns the whole array when size is greater than 1" do
      def r; ary = [1,2]; return *ary; end
      r.should == [1,2]

      def r; ary = [1,2,3]; return *ary; end
      r.should == [1,2,3]
    end

    ruby_version_is "" ... "1.9" do
      it "returns a non-array when used as a splat" do
        def r; value = 1; return *value; end
        r.should == 1
      end
    end

    ruby_version_is "1.9" do
      pending "returns an array when used as a splat" do
        def r; value = 1; return *value; end
        r.should == [1]
      end
    end


    pending "calls 'to_a' on the splatted value first" do
      def r
        obj = Object.new
        def obj.to_a
          [1,2]
        end

        return *obj
      end

      r().should == [1,2]
    end

    ruby_version_is "" ... "1.9" do
      it "calls 'to_ary' on the splatted value first" do
        def r
          obj = Object.new
          def obj.to_ary
            [1,2]
          end

          return *obj
        end

        r().should == [1,2]
      end
    end
  end

  describe "within a begin" do
    before :each do
      ScratchPad.record []
    end

    it "executes ensure before returning" do
      def f()
        begin
          ScratchPad << :begin
          return :begin
          ScratchPad << :after_begin
        ensure
          ScratchPad << :ensure
        end
        ScratchPad << :function
      end
      f().should == :begin
      ScratchPad.recorded.should == [:begin, :ensure]
    end

    it "returns last value returned in ensure" do
      def f()
        begin
          ScratchPad << :begin
          return :begin
          ScratchPad << :after_begin
        ensure
          ScratchPad << :ensure
          return :ensure
          ScratchPad << :after_ensure
        end
        ScratchPad << :function
      end
      f().should == :ensure
      ScratchPad.recorded.should == [:begin, :ensure]
    end

    pending "executes nested ensures before returning" do
      # def f()
      #   begin
      #     begin
      #       ScratchPad << :inner_begin
      #       return :inner_begin
      #       ScratchPad << :after_inner_begin
      #     ensure
      #       ScratchPad << :inner_ensure
      #     end
      #     ScratchPad << :outer_begin
      #     return :outer_begin
      #     ScratchPad << :after_outer_begin
      #   ensure
      #     # ScratchPad << :outer_ensure
      #   end
      #   ScratchPad << :function
      # end
      # f().should == :inner_begin
      # ScratchPad.recorded.should == [:inner_begin, :inner_ensure, :outer_ensure]
    end

    pending "returns last value returned in nested ensures" do
      # def f()
      #   begin
      #     begin
      #       ScratchPad << :inner_begin
      #       return :inner_begin
      #       ScratchPad << :after_inner_begin
      #     ensure
      #       ScratchPad << :inner_ensure
      #       return :inner_ensure
      #       ScratchPad << :after_inner_ensure
      #     end
      #     ScratchPad << :outer_begin
      #     return :outer_begin
      #     ScratchPad << :after_outer_begin
      #   ensure
      #     ScratchPad << :outer_ensure
      #     return :outer_ensure
      #     ScratchPad << :after_outer_ensure
      #   end
      #   ScratchPad << :function
      # end
      # f().should == :outer_ensure
      # ScratchPad.recorded.should == [:inner_begin, :inner_ensure, :outer_ensure]
    end

    it "executes the ensure clause when begin/ensure are inside a lambda" do
      lambda do
        begin
          return
        ensure
          ScratchPad.recorded << :ensure
        end
      end.call
      ScratchPad.recorded.should == [:ensure]
    end
  end

  describe "within a block" do
    before :each do
      ScratchPad.clear
    end

    ruby_version_is "" ... "1.9" do
      it "raises a LocalJumpError if there is no lexicaly enclosing method" do
        def f; yield; end
        lambda { f { return 5 } }.should raise_error(LocalJumpError)
      end
    end

    it "causes lambda to return nil if invoked without any arguments" do
      lambda { return; 456 }.call.should be_nil
    end

    it "causes lambda to return nil if invoked with an empty expression" do
      lambda { return (); 456 }.call.should be_nil
    end

    it "causes lambda to return the value passed to return" do
      lambda { return 123; 456 }.call.should == 123
    end

    pending "causes the method that lexically encloses the block to return" do
      ReturnSpecs::Blocks.new.enclosing_method.should == :return_value
      ScratchPad.recorded.should == :before_return
    end

    pending "returns from the lexically enclosing method even in case of chained calls" do
      ReturnSpecs::NestedCalls.new.enclosing_method.should == :return_value
      ScratchPad.recorded.should == :before_return
    end

    pending "returns from the lexically enclosing method even in case of chained calls(in yield)" do
      ReturnSpecs::NestedBlocks.new.enclosing_method.should == :return_value
      ScratchPad.recorded.should == :before_return
    end

    pending "causes the method to return even when the immediate parent has already returned" do
      ReturnSpecs::SavedInnerBlock.new.start.should == :return_value
      ScratchPad.recorded.should == :before_return
    end

  end

  describe "within two blocks" do
    pending "causes the method that lexically encloses the block to return" do
      def f
        1.times { 1.times {return true}; false}; false
      end
      f.should be_true
    end
  end

  describe "within define_method" do
    pending "goes through the method via a closure" do
      ReturnSpecs::ThroughDefineMethod.new.outer.should == :good
    end

    it "stops at the method when the return is used directly" do
      ReturnSpecs::DefineMethod.new.outer.should == :good
    end
  end
end
