require 'opal/lexer'
require 'opal/grammar'
require 'opal/target_scope'
require 'opal/version'

module Opal
  class Parser

    class Fragment

      attr_reader :code

      def initialize(code, sexp = nil)
        @code = code
        @sexp = sexp
      end

      def to_code
        if @sexp
          "/*:#{@sexp.line}*/#{@code}"
        else
          @code
        end
      end

      def inspect
        "fragment(#{@code.inspect})"
      end
    end

    # Generated code gets indented with two spaces on each scope
    INDENT = '  '

    # Expressions are handled at diffferent levels. Some sexps
    # need to know the js expression they are generating into.
    LEVEL = [:stmt, :stmt_closure, :list, :expr, :recv]

    # All compare method nodes - used to optimize performance of
    # math comparisons
    COMPARE = %w[< > <= >=]

    # Reserved javascript keywords - we cannot create variables with the
    # same name
    RESERVED = %w(
      break case catch continue debugger default delete do else finally for
      function if in instanceof new return switch this throw try typeof var let
      void while with class enum export extends import super true false native
      const static
    )

    # Statements which should not have ';' added to them.
    STATEMENTS = [:xstr, :dxstr, :if]

    attr_reader :result

    def parse(source, options = {})
      @sexp = Grammar.new.parse(source, options[:file])
      @line     = 1
      @indent   = ''
      @unique   = 0

      @helpers  = {
        :breaker  => true,
        :slice    => true
      }

      # options
      @file                     =  options[:file] || '(file)'
      @source_file              =  options[:source_file] || @file
      @method_missing           = (options[:method_missing] != false)
      @optimized_operators      = (options[:optimized_operators] != false)
      @arity_check              =  options[:arity_check]
      @const_missing            = (options[:const_missing] != false)
      @irb_vars                 = (options[:irb] == true)
      @source_map               = (options[:source_map_enabled] != false)

      fragments = self.top(@sexp).flatten

      code = @source_map ? fragments.map(&:to_code).join('') : fragments.map(&:code).join('')

      @result = source_map_comment + version_comment + file_comment + code
    end

    def version_comment
      ""
    end

    def source_map_comment
      @source_map ? "//@ sourceMappingURL=/__opal_source_maps__/#{@file}.js.map\n" : ''
    end

    def file_comment
      @source_map ? "/*-file:#{@source_file}-*/" : ''
    end

    # This is called when a parsing/processing error occurs. This
    # method simply appends the filename and curent line number onto
    # the message and raises it.
    #
    #     parser.error "bad variable name"
    #     # => raise "bad variable name :foo.rb:26"
    #
    # @param [String] msg error message to raise
    def error(msg)
      raise SyntaxError, "#{msg} :#{@file}:#{@line}"
    end

    # This is called when a parsing/processing warning occurs. This
    # method simply appends the filename and curent line number onto
    # the message and issues a warning.
    #
    # @param [String] msg warning message to raise
    def warning(msg)
      warn "#{msg} :#{@file}:#{@line}"
    end

    # Instances of `Scope` can use this to determine the current
    # scope indent. The indent is used to keep generated code easily
    # readable.
    #
    # @return [String]
    def parser_indent
      @indent
    end

    # Create a new sexp using the given parts. Even though this just
    # returns an array, it must be used incase the internal structure
    # of sexps does change.
    #
    #     s(:str, "hello there")
    #     # => [:str, "hello there"]
    #
    # @result [Array]
    def s(*parts)
      sexp = Array.new(parts)
      sexp.line = @line
      sexp
    end

    # @param [String] code the string of code
    # @return [Fragment]
    def fragment(code, sexp = nil)
      Fragment.new(code, sexp)
    end

    # Converts a ruby method name into its javascript equivalent for
    # a method/function call. All ruby method names get prefixed with
    # a '$', and if the name is a valid javascript identifier, it will
    # have a '.' prefix (for dot-calling), otherwise it will be
    # wrapped in brackets to use reference notation calling.
    #
    #     mid_to_jsid('foo')      # => ".$foo"
    #     mid_to_jsid('class')    # => ".$class"
    #     mid_to_jsid('==')       # => "['$==']"
    #     mid_to_jsid('name=')    # => "['$name=']"
    #
    # @param [String] mid ruby method id
    # @return [String]
    def mid_to_jsid(mid)
      if /\=|\+|\-|\*|\/|\!|\?|\<|\>|\&|\||\^|\%|\~|\[/ =~ mid.to_s
        "['$#{mid}']"
      else
        '.$' + mid
      end
    end

    # Used to generate a unique id name per file. These are used
    # mainly to name method bodies for methods that use blocks.
    #
    # @return [String]
    def unique_temp
      "TMP_#{@unique += 1}"
    end

    # Generate the code for the top level sexp, i.e. the root sexp
    # for a file. This is used directly by `#parse`. It pushes a
    # ":top" scope onto the stack and handles the passed in sexp.
    # The result is a string of javascript representing the sexp.
    #
    # @param [Array] sexp the sexp to process
    # @return [String]
    def top(sexp, options = {})
      code, vars = nil, nil

      # empty file = nil as our top sexp
      sexp = s(:nil) unless sexp

      in_scope(:top) do
        indent {
          scope = s(:scope, sexp)
          scope.line = sexp.line

          code = process(scope, :stmt)
          code.unshift fragment(@indent, sexp)
        }

        @scope.add_temp "self = __opal.top"
        @scope.add_temp "__scope = __opal"
        @scope.add_temp "$mm = __opal.mm"
        @scope.add_temp "nil = __opal.nil"
        @scope.add_temp "def = __opal.Object.prototype" if @scope.defines_defn
        @helpers.keys.each { |h| @scope.add_temp "__#{h} = __opal.#{h}" }

        vars = [fragment(INDENT, sexp), @scope.to_vars, fragment("\n", sexp)]

        if @irb_vars
          code.unshift fragment("if (!Opal.irb_vars) { Opal.irb_vars = {}; }\n", sexp)
        end
      end

      [fragment("(function(__opal) {\n", sexp), vars, code, fragment("\n})(Opal);\n", sexp)]
    end

    # Every time the parser enters a new scope, this is called with
    # the scope type as an argument. Valid types are `:top` for the
    # top level/file scope; `:class`, `:module` and `:sclass` for the
    # obvious ruby classes/modules; `:def` and `:iter` for methods
    # and blocks respectively.
    #
    # This method just pushes a new instance of `Opal::Scope` onto the
    # stack, sets the new scope as the `@scope` variable, and yields
    # the given block. Once the block returns, the old scope is put
    # back on top of the stack.
    #
    #     in_scope(:class) do
    #       # generate class body in here
    #       body = "..."
    #     end
    #
    #     # use body result..
    #
    # @param [Symbol] type the type of scope
    # @return [nil]
    def in_scope(type)
      return unless block_given?

      parent = @scope
      @scope = TargetScope.new(type, self).tap { |s| s.parent = parent }
      yield @scope

      @scope = parent
    end

    # To keep code blocks nicely indented, this will yield a block after
    # adding an extra layer of indent, and then returning the resulting
    # code after reverting the indent.
    #
    #   indented_code = indent do
    #     "foo"
    #   end
    #
    # @result [String]
    def indent(&block)
      indent = @indent
      @indent += INDENT
      @space = "\n#@indent"
      res = yield
      @indent = indent
      @space = "\n#@indent"
      res
    end

    # Temporary varibales will be needed from time to time in the
    # generated code, and this method will assign (or reuse) on
    # while the block is yielding, and queue it back up once it is
    # finished. Variables are queued once finished with to save the
    # numbers of variables needed at runtime.
    #
    #     with_temp do |tmp|
    #       "tmp = 'value';"
    #     end
    #
    # @return [String] generated code withing block
    def with_temp(&block)
      tmp = @scope.new_temp
      res = yield tmp
      @scope.queue_temp tmp
      res
    end

    # Used when we enter a while statement. This pushes onto the current
    # scope's while stack so we know how to handle break, next etc.
    #
    # Usage:
    #
    #     in_while do
    #       # generate while body here.
    #     end
    def in_while
      return unless block_given?
      @while_loop = @scope.push_while
      result = yield
      @scope.pop_while

      result
    end

    # Returns true if the parser is curently handling a while sexp,
    # false otherwise.
    #
    # @return [Boolean]
    def in_while?
      @scope.in_while?
    end

    # Processes a given sexp. This will send a method to the receiver
    # of the format "process_<sexp_name>". Any sexp handler should
    # return a string of content.
    #
    # For example, calling `process` with `s(:lit, 42)` will call the
    # method `#process_lit`. If a method with that name cannot be
    # found, then an error is raised.
    #
    #     process(s(:lit, 42), :stmt)
    #     # => "42"
    #
    # @param [Array] sexp the sexp to process
    # @param [Symbol] level the level to process (see `LEVEL`)
    # @return [String]
    def process(sexp, level)
      type = sexp.shift
      meth = "process_#{type}"
      raise "Unsupported sexp: #{type}" unless respond_to? meth

      @line = sexp.line

      __send__(meth, sexp, level)
    end

    # The last sexps in method bodies, for example, need to be returned
    # in the compiled javascript. Due to syntax differences between
    # javascript any ruby, some sexps need to be handled specially. For
    # example, `if` statemented cannot be returned in javascript, so
    # instead the "truthy" and "falsy" parts of the if statement both
    # need to be returned instead.
    #
    # Sexps that need to be returned are passed to this method, and the
    # alterned/new sexps are returned and should be used instead. Most
    # sexps can just be added into a s(:return) sexp, so that is the
    # default action if no special case is required.
    #
    #     sexp = s(:str, "hey")
    #     parser.returns(sexp)
    #     # => s(:js_return, s(:str, "hey"))
    #
    # `s(:js_return)` is just a special sexp used to return the result
    # of processing its arguments.
    #
    # @param [Array] sexp the sexp to alter
    # @return [Array] altered sexp
    def returns(sexp)
      return returns s(:nil) unless sexp

      case sexp.first
      when :break, :next
        sexp
      when :yield
        sexp[0] = :returnable_yield
        sexp
      when :scope
        sexp[1] = returns sexp[1]
        sexp
      when :block
        if sexp.length > 1
          sexp[-1] = returns sexp[-1]
        else
          sexp << returns(s(:nil))
        end
        sexp
      when :when
        sexp[2] = returns(sexp[2])
        sexp
      when :rescue
        sexp[1] = returns sexp[1]
        sexp
      when :ensure
        sexp[1] = returns sexp[1]
        sexp
      when :while
        # sexp[2] = returns(sexp[2])
        sexp
      when :return
        sexp
      when :xstr
        sexp[1] = "return #{sexp[1]};" unless /return|;/ =~ sexp[1]
        sexp
      when :dxstr
        sexp[1] = "return #{sexp[1]}" unless /return|;|\n/ =~ sexp[1]
        sexp
      when :if
        sexp[2] = returns(sexp[2] || s(:nil))
        sexp[3] = returns(sexp[3] || s(:nil))
        sexp
      else
        s(:js_return, sexp).tap { |s|
          s.line = sexp.line
        }
      end
    end

    # Returns true if the given sexp is an expression. All expressions
    # will get ';' appended to their result, except for the statement
    # sexps. See `STATEMENTS` for a list of sexp names that are
    # statements.
    #
    # @param [Array] sexp the sexp to check
    # @return [Boolean]
    def expression?(sexp)
      !STATEMENTS.include?(sexp.first)
    end

    # More than one expression in a row will be grouped by the grammar
    # into a block sexp. A block sexp just holds any number of other
    # sexps.
    #
    #     s(:block, s(:str, "hey"), s(:lit, 42))
    #
    # A block can actually be empty. As opal requires real values to
    # be returned (to appease javascript values), a nil sexp
    # s(:nil) will be generated if the block is empty.
    #
    # @return [String]
    def process_block(sexp, level)
      result = []
      sexp << s(:nil) if sexp.empty?

      join = (@scope.class_scope? ? "\n\n#@indent" : "\n#@indent")

      until sexp.empty?
        stmt = sexp.shift

        result << fragment(join, sexp) unless result.empty?

        # find any inline yield statements
        if yasgn = find_inline_yield(stmt)
          result << process(yasgn, level)
          result << fragment(";", yasgn)
        end

        expr = expression?(stmt) and LEVEL.index(level) < LEVEL.index(:list)

        code = process(stmt, level)

        result << code
        if expr
          result << fragment(";", stmt)
        end
      end

      result
    end

    # When a block sexp gets generated, any inline yields (i.e. yield
    # statements that are not direct members of the block) need to be
    # generated as a top level member. This is because if a yield
    # is returned by a break statement, then the method must return.
    #
    # As inline expressions in javascript cannot return, the block
    # must be rewritten.
    #
    # For example, a yield inside an array:
    #
    #     [1, 2, 3, yield(4)]
    #
    # Must be rewitten into:
    #
    #     tmp = yield 4
    #     [1, 2, 3, tmp]
    #
    # This rewriting happens on sexps directly.
    #
    # @param [Sexp] stmt sexps to (maybe) rewrite
    # @return [Sexp]
    def find_inline_yield(stmt)
      found = nil
      case stmt.first
      when :js_return
        found = find_inline_yield stmt[1]
      when :array
        stmt[1..-1].each_with_index do |el, idx|
          if el.first == :yield
            found = el
            stmt[idx+1] = s(:js_tmp, '__yielded')
          end
        end
      when :call
        arglist = stmt[3]
        arglist[1..-1].each_with_index do |el, idx|
          if el.first == :yield
            found = el
            arglist[idx+1] = s(:js_tmp, '__yielded')
          end
        end
      end

      if found
        @scope.add_temp '__yielded' unless @scope.has_temp? '__yielded'
        s(:yasgn, '__yielded', found)
      end
    end

    def process_scope(sexp, level)
      stmt = sexp.shift
      if stmt
        unless @scope.class_scope?
          stmt = returns stmt
        end

        process stmt, :stmt
      else
        fragment("nil", sexp)
      end
    end

    # s(:js_return, sexp)
    def process_js_return(sexp, level)
      [fragment("return ", sexp), process(sexp.shift, :expr)]
    end

    # s(:js_tmp, str)
    def process_js_tmp(sexp, level)
      fragment(sexp.shift.to_s, sexp)
    end

    def process_operator(sexp, level)
      meth, recv, arg = sexp
      mid = mid_to_jsid meth.to_s
      result = []

      if @optimized_operators
        with_temp do |a|
          with_temp do |b|
            l = process recv, :expr
            r = process arg, :expr

            result << fragment("(#{a} = ", sexp)
            result << l
            result << fragment(", #{b} = ", sexp)
            result << r
            result << fragment(", typeof(#{a}) === 'number' ? #{a} #{meth} #{b} ", sexp)
            result << fragment(": #{a}#{mid}(#{b}))", sexp)
          end
        end
      else
        "#{process recv, :recv}#{mid}(#{process arg, :expr})"
      end

      result
    end

    def js_block_given(sexp, level)
      @scope.uses_block!
      if @scope.block_name
        fragment("(#{@scope.block_name} !== nil)", sexp)
      else
        fragment("false", sexp)
      end
    end

    def handle_block_given(sexp, reverse = false)
      @scope.uses_block!
      name = @scope.block_name

      fragment((reverse ? "#{ name } === nil" : "#{ name } !== nil"), sexp)
    end

    # s(:lit, 1)
    # s(:lit, :foo)
    def process_lit(sexp, level)
      val = sexp.shift
      case val
      when Numeric
        if level == :recv
          fragment("(#{val.inspect})", sexp)
        else
          fragment(val.inspect, sexp)
        end
      when Symbol
        fragment(val.to_s.inspect, sexp)
      when Regexp
        fragment((val == // ? /^/.inspect : val.inspect), sexp)
      when Range
        @helpers[:range] = true
        "__range(#{val.begin}, #{val.end}, #{val.exclude_end?})"
      else
        raise "Bad lit: #{val.inspect}"
      end
    end

    def process_dregx(sexp, level)
      result = []

      sexp.each do |part|
        result << fragment(" + ", sexp) unless result.empty?

        if String === part
          result << fragment(part.inspect, sexp)
        elsif part[0] == :str
          result << process(part, :expr)
        else
          result << process(part[1], :expr)
        end
      end

      [fragment("(new RegExp(", sexp), result, fragment("))", sexp)]
    end

    def process_dot2(sexp, level)
      lhs = process sexp[0], :expr
      rhs = process sexp[1], :expr
      @helpers[:range] = true

      [fragment("__range(", sexp), lhs, fragment(", ", sexp), rhs, fragment(", false)", sexp)]
    end

    def process_dot3(sexp, level)
      lhs = process sexp[0], :expr
      rhs = process sexp[1], :expr
      @helpers[:range] = true

      [fragment("__range(", sexp), lhs, fragment(", ", sexp), rhs, fragment(", true)", sexp)]
    end

    # s(:str, "string")
    def process_str(sexp, level)
      str = sexp.shift
      if str == @file
        @uses_file = true
        fragment(@file.inspect, sexp)
      else
        fragment(str.inspect, sexp)
      end
    end

    def process_defined(sexp, level)
      part = sexp[0]
      case part[0]
      when :self
        fragment("self".inspect, sexp)
      when :nil
        fragment("nil".inspect, sexp)
      when :true
        fragment("true".inspect, sexp)
      when :false
        fragment("false".inspect, sexp)
      when :call
        mid = mid_to_jsid part[2].to_s
        recv = part[1] ? process(part[1], :expr) : fragment(current_self, sexp)
        [fragment("(", sexp), recv, fragment("#{mid} ? 'method' : nil)", sexp)]
      when :xstr
        [fragment("(typeof(", sexp), process(part, :expr), fragment(") !== 'undefined')", sexp)]
      when :const
        fragment("(__scope.#{part[1].to_s} != null)", sexp)
      when :colon2
        fragment("false", sexp)
      when :ivar
        ivar_name = part[1].to_s[1..-1]
        with_temp do |t|
          fragment("((#{t} = #{current_self}[#{ivar_name.inspect}], #{t} != null && #{t} !== nil) ? 'instance-variable' : nil)", sexp)
        end
      when :lvar
        fragment("local-variable", sexp)
      else
        raise "bad defined? part: #{part[0]}"
      end
    end

    # s(:not, sexp)
    def process_not(sexp, level)
      with_temp do |tmp|
        expr = sexp.shift
        [fragment("(#{tmp} = ", sexp), process(expr, :expr), fragment(", (#{tmp} === nil || #{tmp} === false))", sexp)]
      end
    end

    def process_block_pass(exp, level)
      process(s(:call, exp.shift, :to_proc, s(:arglist)), :expr)
    end

    # s(:iter, call, block_args [, body)
    def process_iter(sexp, level)
      call, args, body = sexp

      body ||= s(:nil)
      body = returns body
      code = []
      params = nil
      scope_name = nil
      identity = nil
      to_vars = nil

      args = nil if Fixnum === args # argh
      args ||= s(:masgn, s(:array))
      args = args.first == :lasgn ? s(:array, args) : args[1]

      if args.last.is_a?(Array) and args.last[0] == :block_pass
        block_arg = args.pop
        block_arg = block_arg[1][1].to_sym
      end

      if args.last.is_a?(Array) and args.last[0] == :splat
        splat = args.last[1][1]
        args.pop
        len = args.length
      end

      indent do
        in_scope(:iter) do
          identity = @scope.identify!
          @scope.add_temp "#{current_self} = #{identity}._s || this"

          args[1..-1].each do |arg|
            arg = arg[1]
            arg = "#{arg}$" if RESERVED.include? arg.to_s
            code << fragment("if (#{arg} == null) #{arg} = nil;\n", sexp)
          end

          params = js_block_args(args[1..-1])

          if splat
            @scope.add_arg splat
            params << splat
            code << fragment("#{splat} = __slice.call(arguments, #{len - 1});", sexp)
          end

          if block_arg
            @scope.block_name = block_arg
            @scope.add_temp block_arg
            @scope.add_temp '__context'
            scope_name = @scope.identify!

            blk = []
            blk << fragment("\n#@indent#{block_arg} = #{scope_name}._p || nil, #{scope_name}.p = null;\n#@indent", sexp)

            code.unshift blk
          end

          code << fragment("\n#@indent", sexp)
          code << process(body, :stmt)

          if @scope.defines_defn
            @scope.add_temp "def = ((typeof(#{current_self}) === 'function') ? #{current_self}.prototype : #{current_self})"
          end

          to_vars = [fragment("\n#@indent", sexp), @scope.to_vars, fragment("\n#@indent", sexp)]
        end
      end

      itercode = [fragment("function(#{params.join ', '}) {\n", sexp), to_vars, code, fragment("\n#@indent}", sexp)]

      itercode.unshift fragment("(#{identity} = ", sexp)
      itercode << fragment(", #{identity}._s = #{current_self}, #{identity})", sexp)

      call << itercode
      process call, level
    end

    def js_block_args(sexp)
      sexp.map do |arg|
        a = arg[1].to_sym
        a = "#{a}$".to_sym if RESERVED.include? a.to_s
        @scope.add_arg a
        a
      end
    end

    ##
    # recv.mid = rhs
    #
    # s(recv, :mid=, s(:arglist, rhs))
    def process_attrasgn(exp, level)
      recv, mid, arglist = exp
      process s(:call, recv, mid, arglist), level
    end

    # Used to generate optimized attr_reader, attr_writer and
    # attr_accessor methods. These are optimized to avoid the added
    # cost of converting the method id's into jsid's at runtime.
    #
    # This method will only be called if all the given ids are strings
    # or symbols. Any dynamic arguments will default to being called
    # using the Module#attr_* methods as expected.
    #
    # @param [Symbol] meth :attr_{reader,writer,accessor}
    # @param [Array<Sexp>] attrs array of s(:lit) or s(:str)
    # @return [String] precompiled attr methods
    def handle_attr_optimize(meth, attrs)
      out = []

      attrs.each do |attr|
        mid  = attr[1]
        ivar = "@#{mid}".to_sym

        unless meth == :attr_writer
          out << fragment(", \n#@indent") unless out.empty?
          out << process(s(:defn, mid, s(:args), s(:scope, s(:ivar, ivar))), :stmt)
        end

        unless meth == :attr_reader
          out << fragment(", \n#@indent") unless out.empty?
          mid = "#{mid}=".to_sym
          out << process(s(:defn, mid, s(:args, :val), s(:scope,
                    s(:iasgn, ivar, s(:lvar, :val)))), :stmt)
        end
      end

      out << fragment(", nil")
      out
    end

    # s(:call, recv, :mid, s(:arglist))
    # s(:call, nil, :mid, s(:arglist))
    def process_call(sexp, level)
      recv, meth, arglist, iter = sexp
      mid = mid_to_jsid meth.to_s

      # we are trying to access a lvar in irb mode
      if @irb_vars and @scope.top? and arglist == s(:arglist) and recv == nil
        return with_temp { |t|
          lvar = meth.intern
          lvar = "#{lvar}$" if RESERVED.include? lvar
          call = s(:call, s(:self), meth.intern, s(:arglist))
          [fragment("((#{t} = Opal.irb_vars.#{lvar}) == null ? ", sexp), process(call, :expr), fragment(" : #{t})", sexp)]
        }
      end

      case meth
      when :attr_reader, :attr_writer, :attr_accessor
        return handle_attr_optimize(meth, arglist[1..-1]) if @scope.class_scope?
      when :block_given?
        return js_block_given(sexp, level)
      end

      splat = arglist[1..-1].any? { |a| a.first == :splat }

      if Array === arglist.last and arglist.last.first == :block_pass
        block = process(arglist.pop, :expr)
      elsif iter
        block = iter
      end

      recv ||= s(:self)

      if block
        tmpfunc = @scope.new_temp
      end

      tmprecv = @scope.new_temp
      args      = ""

      recv_code = process recv, :recv

      if @method_missing
        call_recv = s(:js_tmp, tmprecv || recv_code)
        arglist.insert 1, call_recv unless splat
        args = process arglist, :expr

        dispatch = "((#{tmprecv} = #{recv_code})#{mid} || $mm('#{meth.to_s}'))"
        dispatch = [fragment("((#{tmprecv} = ", sexp), recv_code, fragment(")#{mid} || $mm('#{meth.to_s}'))", sexp)]

        if tmpfunc
          dispatch.unshift fragment("(#{tmpfunc} = ", sexp)
          dispatch << fragment(", #{tmpfunc}._p = ", sexp)
          dispatch << block
          dispatch << fragment(", #{tmpfunc})", sexp)
        end

        if splat
          dispatch << fragment(".apply(", sexp)
          dispatch << process(call_recv, :expr)
          dispatch << fragment(", ", sexp)
          dispatch << args
          dispatch << fragment(")", sexp)
        else
          dispatch << fragment(".call(", sexp)
          dispatch.push(*args)
          dispatch << fragment(")", sexp)
        end

        result = dispatch
      else 
        # args = process arglist, :expr
        # dispatch = tmprecv ? "(#{tmprecv} = #{recv_code})#{mid}" : "#{recv_code}#{mid}"
        # result = splat ? "#{dispatch}.apply(#{tmprecv || recv_code}, #{args})" : "#{dispatch}(#{args})"
        
        call_recv = s(:js_tmp, tmprecv || recv_code)
        args = process arglist, :expr
        
        dispatch = [fragment("(#{tmprecv} = ", sexp), recv_code, fragment(")#{mid}", sexp)]
        
        if tmpfunc
          dispatch.unshift fragment("(#{tmpfunc} = ", sexp)
          dispatch << fragment(", #{tmpfunc}._p = ", sexp)
          dispatch << block
          dispatch << fragment(", #{tmpfunc})", sexp)
        end
        
        if splat
          dispatch << fragment(".apply(", sexp)
          dispatch << process(call_recv, :expr)
          dispatch << fragment(", ", sexp)
          dispatch << args
          dispatch << fragment(")", sexp)
        else
          if tmpfunc
            dispatch <<  fragment(".call(", sexp)
            dispatch << process(call_recv, :expr)
            dispatch << fragment(", ", sexp) if args.any?
          else
            dispatch << fragment("(", sexp)
          end
          
          dispatch.push(*args)
          dispatch << fragment(")", sexp)
        end
        
        result = dispatch
      end

      @scope.queue_temp tmpfunc if tmpfunc
      result
    end

    # s(:arglist, [arg [, arg ..]])
    def process_arglist(sexp, level)
      code = []
      work = []

      until sexp.empty?
        current = sexp.shift
        splat = current.first == :splat
        arg   = process current, :expr

        if splat
          if work.empty?
            if code.empty?
              code << fragment("[].concat(", sexp)
              code << arg
              code << fragment(")", sexp)
            else
              code += ".concat(#{arg})"
            end
          else
            if code.empty?
              code << [fragment("[", sexp), work, fragment("]", sexp)]
            else
              code << [fragment(".concat([", sexp), work, fragment("])", sexp)]
            end

            code << [fragment(".concat(", sexp), arg, fragment(")", sexp)]
          end

          work = []
        else
          work << fragment(", ", current) unless work.empty?
          work.push(*arg)
        end
      end

      unless work.empty?
        join = work

        if code.empty?
          code = join
        else
          code << fragment(".concat(", sexp) << join << fragment(")", sexp)
        end
      end

      code
    end

    # s(:splat, sexp)
    def process_splat(sexp, level)
      if sexp.first == [:nil]
        [fragment("[]", sexp)]
      elsif sexp.first.first == :lit
        [fragment("[", sexp), process(sexp.first, :expr), fragment("]", sexp)]
      else
        process sexp.first, :recv
      end
    end

    # s(:class, cid, super, body)
    def process_class(sexp, level)
      cid, sup, body = sexp

      body[1] = s(:nil) unless body[1]

      code = []
      @helpers[:klass] = true

      if Symbol === cid or String === cid
        base = process(s(:self), :expr)
        name = cid.to_s
      elsif cid[0] == :colon2
        base = process(cid[1], :expr)
        name = cid[2].to_s
      elsif cid[0] == :colon3
        base = process(s(:js_tmp, 'Opal.Object'), :expr)
        name = cid[1].to_s
      else
        raise "Bad receiver in class"
      end

      sup = sup ? process(sup, :expr) : process(s(:js_tmp, 'null'), :expr)

      indent do
        in_scope(:class) do
          @scope.name = name
          @scope.add_temp "#{ @scope.proto } = #{name}.prototype", "__scope = #{name}._scope"

          if Array === body.last
            # A single statement will need a block
            needs_block = body.last.first != :block
            body.last.first == :block
            last_body_statement = needs_block ? body.last : body.last.last

            if last_body_statement and Array === last_body_statement
              if [:defn, :defs].include? last_body_statement.first
                body[-1] = s(:block, body[-1]) if needs_block
                body.last << s(:nil)
              end
            end
          end

          body = returns(body)
          body = process body, :stmt
          code << fragment("\n", sexp)
          code << @scope.to_donate_methods

          code << fragment(@indent, sexp)
          code << @scope.to_vars
          code << fragment("\n\n#@indent", sexp)
          code << body
        end
      end

      spacer  = "\n#{@indent}#{INDENT}"
      cls     = "function #{name}() {};"
      boot    = "#{name} = __klass(__base, __super, #{name.inspect}, #{name});"

      [fragment("(function(__base, __super){#{spacer}#{cls}#{spacer}#{boot}\n", sexp),
       code, fragment("\n#@indent})", sexp), fragment("(", sexp), base, fragment(", ", sexp), sup, fragment(")", sexp)]
    end

    # s(:sclass, recv, body)
    def process_sclass(sexp, level)
      recv = sexp[0]
      body = sexp[1]
      code = []

      in_scope(:sclass) do
        @scope.add_temp "__scope = #{current_self}._scope"
        @scope.add_temp "def = #{current_self}.prototype"

        body = process body, :stmt
        code << @scope.to_vars << body
      end

      result = []
      result << fragment("(function(){", sexp) << code
      result << fragment("}).call(__opal.singleton(", sexp)
      result << process(recv, :expr) << fragment("))", sexp)
      result
    end

    # s(:module, cid, body)
    def process_module(sexp, level)
      cid = sexp[0]
      body = sexp[1]
      code = []
      @helpers[:module] = true

      if Symbol === cid or String === cid
        base = process(s(:self), :expr)
        name = cid.to_s
      elsif cid[0] == :colon2
        base = process(cid[1], :expr)
        name = cid[2].to_s
      elsif cid[0] == :colon3
        base = fragment('Opal.Object', sexp)
        name = cid[1].to_s
      else
        raise "Bad receiver in class"
      end

      indent do
        in_scope(:module) do
          @scope.name = name
          @scope.add_temp "#{ @scope.proto } = #{name}.prototype", "__scope = #{name}._scope"
          body = process body, :stmt

          code << fragment(@indent, sexp)
          code.push(*@scope.to_vars)
          code << fragment("\n\n#@indent", sexp)
          code.push(*body)
          code << fragment("\n#@ident", sexp)
          code.push(*@scope.to_donate_methods)
        end
      end

      spacer  = "\n#{@indent}#{INDENT}"
      cls     = "function #{name}() {};"
      boot    = "#{name} = __module(__base, #{name.inspect}, #{name});"

      code.unshift fragment("(function(__base){#{spacer}#{cls}#{spacer}#{boot}\n", sexp)
      code << fragment("\n#@indent})(", sexp)
      code.push(*base)
      code << fragment(")", sexp)

      code
    end

    # undef :foo
    # => delete MyClass.prototype.$foo
    def process_undef(sexp, level)
      fragment("delete #{ @scope.proto }#{ mid_to_jsid sexp[0][1].to_s }", sexp)
    end

    # s(:defn, mid, s(:args), s(:scope))
    def process_defn(sexp, level)
      mid, args, stmts = sexp

      js_def nil, mid, args, stmts, sexp.line, sexp.end_line, sexp
    end

    # s(:defs, recv, mid, s(:args), s(:scope))
    def process_defs(sexp, level)
      recv, mid, args, stmts = sexp

      js_def recv, mid, args, stmts, sexp.line, sexp.end_line, sexp
    end

    def js_def(recvr, mid, args, stmts, line, end_line, sexp)
      jsid = mid_to_jsid mid.to_s

      if recvr
        @scope.defines_defs = true
        smethod = true if @scope.class_scope? && recvr.first == :self
        recv = process(recvr, :expr)
      else
        @scope.defines_defn = true
        recv = current_self
      end

      code = []
      params = nil
      scope_name = nil
      uses_super = nil
      uses_splat = nil

      # opt args if last arg is sexp
      opt = args.pop if Array === args.last

      argc = args.length - 1

      # block name &block
      if args.last.to_s.start_with? '&'
        block_name = args.pop.to_s[1..-1].to_sym
        argc -= 1
      end

      # splat args *splat
      if args.last.to_s.start_with? '*'
        uses_splat = true
        if args.last == :*
          argc -= 1
        else
          splat = args[-1].to_s[1..-1].to_sym
          args[-1] = splat
          argc -= 1
        end
      end

      if @arity_check
        arity_code = arity_check(args, opt, uses_splat, block_name, mid) + "\n#{INDENT}"
      end

      indent do
        in_scope(:def) do
          @scope.mid  = mid
          @scope.defs = true if recvr

          if block_name
            @scope.uses_block!
          end

          yielder = block_name || '__yield'
          @scope.block_name = yielder

          params = process args, :expr
          stmt_code = [fragment("\n#@indent", stmts), *process(stmts, :stmt)]

          opt[1..-1].each do |o|
            next if o[2][2] == :undefined
            code << fragment("if (#{o[1]} == null) {\n#{@indent + INDENT}", o)
            code << process(o, :expr)
            code << fragment("\n#{@indent}}", o)
          end if opt

          code << fragment("#{splat} = __slice.call(arguments, #{argc});", sexp) if splat

          scope_name = @scope.identity

          if @scope.uses_block?
            @scope.add_temp yielder
            blk = fragment(("\n%s%s = %s._p || nil, %s._p = null;\n%s" %
                            [@indent, yielder, scope_name, scope_name, @indent]), sexp)
          end

          code.push(*stmt_code)
          code.unshift blk if blk

          uses_super = @scope.uses_super

          code = [fragment("#{arity_code}#@indent", sexp), @scope.to_vars, code]
        end
      end

      result = [fragment("#{"#{scope_name} = " if scope_name}function(", sexp)]
      result.push(*params)
      result << fragment(") {\n", sexp)
      result.push(*code)
      result << fragment("\n#@indent}", sexp)

      if recvr
        if smethod
          [fragment("__opal.defs(#{@scope.name}, '$#{mid}', ", sexp), result, fragment(")", sexp)]
        else
          [recv, fragment("#{jsid} = ", sexp), result]
        end
      elsif @scope.class? and @scope.name == 'Object'
        [fragment("#{current_self}._defn('$#{mid}', ", sexp), result, fragment(")", sexp)]
      elsif @scope.class_scope?
        @scope.methods << "$#{mid}"
        if uses_super
          @scope.add_temp uses_super
          uses_super = "#{uses_super} = #{@scope.proto}#{jsid};\n#@indent"
        end

        [fragment("#{uses_super}#{@scope.proto}#{jsid} = ", sexp), result]
      elsif @scope.type == :iter
        [fragment("def#{jsid} = ", sexp), result]
      elsif @scope.type == :top
        [fragment("def#{ jsid } = ", sexp), *result]
      else
        [fragment("def#{jsid} = ", sexp), result]
      end
    end

    ##
    # Returns code used in debug mode to check arity of method call
    def arity_check(args, opt, splat, block_name, mid)
      meth = mid.to_s.inspect

      arity = args.size - 1
      arity -= (opt.size - 1) if opt
      arity -= 1 if splat
      arity = -arity - 1 if opt or splat

      # $arity will point to our received arguments count
      aritycode = "var $arity = arguments.length;"

      if arity < 0 # splat or opt args
        aritycode + "if ($arity < #{-(arity + 1)}) { __opal.ac($arity, #{arity}, this, #{meth}); }"
      else
        aritycode + "if ($arity !== #{arity}) { __opal.ac($arity, #{arity}, this, #{meth}); }"
      end
    end

    def process_args(exp, level)
      args = []

      until exp.empty?
        a = exp.shift.to_sym
        next if a.to_s == '*'
        a = "#{a}$".to_sym if RESERVED.include? a.to_s
        @scope.add_arg a
        args << a
      end

      [fragment(args.join(', '), exp)]
    end

    # s(:self)  # => this
    def process_self(sexp, level)
      fragment(current_self, sexp)
    end

    # Returns the current value for 'self'. This will be native
    # 'this' for methods and blocks, and the class name for class
    # and module bodies.
    def current_self
      if @scope.class_scope?
        @scope.name
      elsif @scope.top? or @scope.iter?
        'self'
      else # defn, defs
        'this'
      end
    end

    def process_true(sexp, level)
      fragment("true", sexp)
    end

    def process_false(sexp, level)
      fragment("false", sexp)
    end

    def process_nil(sexp, level)
      fragment("nil", sexp)
    end

    # s(:array [, sexp [, sexp]])
    def process_array(sexp, level)
      return [fragment("[]", sexp)] if sexp.empty?

      code = []
      work = []

      until sexp.empty?
        current = sexp.shift
        splat = current.first == :splat
        part  = process current, :expr

        if splat
          if work.empty?
            if code.empty?
              code << fragment("[].concat(", sexp) << part << fragment(")", sexp)
            else
              code << fragment(".concat(", sexp) << part << fragment(")", sexp)
            end
          else
            if code.empty?
              code << fragment("[", sexp) << work << fragment("]", sexp)
            else
              code << fragment(".concat([", sexp) << work << fragment("])", sexp)
            end

            code << fragment(".concat(", sexp) << part << fragment(")", sexp)
          end
          work = []
        else
          work << fragment(", ", current) unless work.empty?
          work << part
        end
      end

      unless work.empty?
        join = [fragment("[", sexp), work, fragment("]", sexp)]

        if code.empty?
          code = join
        else
          code.push([fragment(".concat(", sexp), join, fragment(")", sexp)])
        end
      end

      code
    end

    # s(:hash, key1, val1, key2, val2...)
    def process_hash(sexp, level)
      keys = []
      vals = []

      sexp.each_with_index do |obj, idx|
        if idx.even?
          keys << obj
        else
          vals << obj
        end
      end

      if keys.all? { |k| [:lit, :str].include? k[0] }
        hash_obj  = {}
        hash_keys = []
        keys.size.times do |i|
          k = keys[i][1].to_s.inspect
          hash_keys << k unless hash_obj.include? k
          hash_obj[k] = process(vals[i], :expr)
        end

        result = []
        @helpers[:hash2] = true

        hash_keys.each do |k|
          result << fragment(", ", sexp) unless result.empty?
          result << fragment("#{k}: ", sexp)
          result << hash_obj[k]
        end

        [fragment("__hash2([#{hash_keys.join ', '}], {", sexp), result, fragment("})", sexp)]
      else
        @helpers[:hash] = true
        result = []

        sexp.each do |p|
          result << fragment(", ", p) unless result.empty?
          result << process(p, :expr)
        end

        [fragment("__hash(", sexp), result, fragment(")", sexp)]
      end
    end

    # s(:while, exp, block, true)
    def process_while(sexp, level)
      expr, stmt = sexp
      redo_var = @scope.new_temp
      code = []

      stmt_level = if level == :expr or level == :recv
                     :stmt_closure
                    else
                      :stmt
                    end

      code << js_truthy(expr) << fragment("){", sexp)
      pre = "while ("

      in_while do
        @while_loop[:closure] = true if stmt_level == :stmt_closure
        @while_loop[:redo_var] = redo_var
        body = process(stmt, :stmt)

        if @while_loop[:use_redo]
          pre = "#{redo_var}=false;" + pre + "#{redo_var} || "
          code << fragment("#{redo_var}=false;", sexp)
        end

        code << body
      end

      code << fragment("}", sexp)
      code.unshift fragment(pre, sexp)
      @scope.queue_temp redo_var

      if stmt_level == :stmt_closure
#        code = "(function() {#{code}}).call(#{current_self})"
        code.unshift fragment("(function() {", sexp)
        code.push fragment("}).call(#{current_self})", sexp)
      end

      code
    end

    def process_until(exp, level)
      expr = exp[0]
      stmt = exp[1]
      redo_var   = @scope.new_temp
      stmt_level = if level == :expr or level == :recv
                     :stmt_closure
                   else
                     :stmt
                   end

      code = []
      pre = "while (!("
      code << js_truthy(expr) << fragment(")) {", exp)

      in_while do
        @while_loop[:closure] = true if stmt_level == :stmt_closure
        @while_loop[:redo_var] = redo_var
        body = process(stmt, :stmt)

        if @while_loop[:use_redo]
          pre = "#{redo_var}=false;" + pre + "#{redo_var} || "
          code << fragment("#{redo_var}=false;", exp)
        end

        code << body
      end

      code << fragment("}", exp)
      code.unshift fragment(pre, exp)
      @scope.queue_temp redo_var

      if stmt_level == :stmt_closure
#        code = "(function() {#{code}}).call(#{current_self})"
        code.unshift fragment("(function() {", exp)
        code << fragment("}).call(#{current_self})", exp)
      end

      code
    end

    # alias foo bar
    #
    # s(:alias, s(:lit, :foo), s(:lit, :bar))
    def process_alias(exp, level)
      new = mid_to_jsid exp[0][1].to_s
      old = mid_to_jsid exp[1][1].to_s

      if [:class, :module].include? @scope.type
        @scope.methods << "$#{exp[0][1].to_s}"
        fragment("%s%s = %s%s" % [@scope.proto, new, @scope.proto, old], exp)
      else
        current = current_self
        fragment("%s.prototype%s = %s.prototype%s" % [current, new, current, old], exp)
      end
    end

    def process_masgn(sexp, level)
      lhs = sexp[0]
      rhs = sexp[1]
      tmp = @scope.new_temp
      len = 0
      code = []

      # remote :array part
      lhs.shift
      if rhs[0] == :array
        len = rhs.length - 1 # we are guaranteed an array of this length
        code << fragment("#{tmp} = ", sexp) << process(rhs, :expr)
      elsif rhs[0] == :to_ary
        code << fragment("((#{tmp} = ", sexp) << process(rhs[1], :expr)
        code << fragment(")._isArray ? #{tmp} : (#{tmp} = [#{tmp}]))", sexp)
      elsif rhs[0] == :splat
        code << fragment("(#{tmp} = ", sexp) << process(rhs[1], :expr)
        code << fragment(")['$to_a'] ? (#{tmp} = #{tmp}['$to_a']()) : (#{tmp})._isArray ?  #{tmp} : (#{tmp} = [#{tmp}])", sexp)
      else
        raise "Unsupported mlhs type"
      end

      lhs.each_with_index do |l, idx|
        code << fragment(", ", sexp) unless code.empty?

        if l.first == :splat
          s = l[1]
          s << s(:js_tmp, "__slice.call(#{tmp}, #{idx})")
          code << process(s, :expr)
        else
          if idx >= len
            l << s(:js_tmp, "(#{tmp}[#{idx}] == null ? nil : #{tmp}[#{idx}])")
          else
            l << s(:js_tmp, "#{tmp}[#{idx}]")
          end
          code << process(l, :expr)
        end
      end

      @scope.queue_temp tmp
      code
    end

    def process_svalue(sexp, level)
      process sexp.shift, level
    end

    # s(:lasgn, :lvar, rhs)
    def process_lasgn(sexp, level)
      lvar = sexp[0]
      rhs  = sexp[1]
      lvar = "#{lvar}$".to_sym if RESERVED.include? lvar.to_s

      if @irb_vars and @scope.top?
        [fragment("Opal.irb_vars.#{lvar} = ", sexp), process(rhs, :expr)]
      else
        @scope.add_local lvar
        rhs = process(rhs, :expr)
        result =  [fragment(lvar, sexp), fragment(" = ", sexp), rhs]

        if level == :recv
          result.unshift fragment("(", sexp)
          result.push fragment(")", sexp)
        end

        result
      end
    end

    # s(:lvar, :lvar)
    def process_lvar(sexp, level)
      lvar = sexp.shift.to_s
      lvar = "#{lvar}$" if RESERVED.include? lvar

      if @irb_vars and @scope.top?
        with_temp { |t| fragment("((#{t} = Opal.irb_vars.#{lvar}) == null ? nil : #{t})", sexp) }
      else
        fragment(lvar, sexp)
      end
    end

    # s(:iasgn, :ivar, rhs)
    def process_iasgn(exp, level)
      ivar = exp[0]
      rhs = exp[1]
      ivar = ivar.to_s[1..-1]
      lhs = RESERVED.include?(ivar) ? "#{current_self}['#{ivar}']" : "#{current_self}.#{ivar}"
      [fragment(lhs, exp), fragment(" = ", exp), process(rhs, :expr)]
    end

    # s(:ivar, :ivar)
    def process_ivar(exp, level)
      ivar = exp.shift.to_s[1..-1]
      part = RESERVED.include?(ivar) ? "['#{ivar}']" : ".#{ivar}"
      @scope.add_ivar part
      fragment("#{current_self}#{part}", exp)
    end

    # s(:gvar, gvar)
    def process_gvar(sexp, level)
      gvar = sexp.shift.to_s[1..-1]
      @helpers['gvars'] = true
      fragment("__gvars[#{gvar.inspect}]", sexp)
    end

    def process_nth_ref(sexp, level)
      fragment("nil", sexp)
    end

    # s(:gasgn, :gvar, rhs)
    def process_gasgn(sexp, level)
      gvar = sexp[0].to_s[1..-1]
      rhs  = sexp[1]
      @helpers['gvars'] = true
      [fragment("__gvars[#{gvar.to_s.inspect}] = ", sexp), process(rhs, :expr)]
    end

    # s(:const, :const)
    def process_const(sexp, level)
      cname = sexp.shift.to_s

      if @const_missing
        with_temp do |t|
          fragment("((#{t} = __scope.#{cname}) == null ? __opal.cm(#{cname.inspect}) : #{t})", sexp)
        end
      else
        fragment("__scope.#{cname}", sexp)
      end
    end

    # s(:cdecl, :const, rhs)
    def process_cdecl(sexp, level)
      const, rhs = sexp
      [fragment("__scope.#{const} = ", sexp), process(rhs, :expr)]
    end

    # s(:return [val])
    def process_return(sexp, level)
      val = process(sexp.shift || s(:nil), :expr)

      raise SyntaxError, "void value expression: cannot return as an expression" unless level == :stmt
      [fragment("return ", sexp), val]
    end

    # s(:xstr, content)
    def process_xstr(sexp, level)
      code = sexp.first.to_s
      code += ";" if level == :stmt and !code.include?(';')

      result = fragment(code, sexp)

      level == :recv ? [fragment("(", sexp), result, fragment(")", sexp)] : result
    end

    # s(:dxstr, parts...)
    def process_dxstr(sexp, level)
      result = []
      needs_sc = false

      sexp.each do |p|
        if String === p
          result << fragment(p.to_s, sexp)
          needs_sc = true if level == :stmt and !p.to_s.include?(';')
        elsif p.first == :evstr
          result.push(*process(p.last, :stmt))
        elsif p.first == :str
          result << fragment(p.last.to_s, p)
          needs_sc = true if level == :stmt and !p.last.to_s.include?(';')
        else
          raise "Bad dxstr part"
        end
      end

      result << fragment(";", sexp) if needs_sc

      if level == :recv
        [fragment("(", sexp), result, fragment(")", sexp)]
      else
        result
      end
    end

    # s(:dstr, parts..)
    def process_dstr(sexp, level)
      result = []

      sexp.each do |p|
        result << fragment(" + ", sexp) unless result.empty?
        if String === p
          result << fragment(p.inspect, sexp)
        elsif p.first == :evstr
          result << fragment("(", p)
          result << process(p.last, :expr)
          result << fragment(")", p)
        elsif p.first == :str
          result << fragment(p.last.inspect, p)
        else
          raise "Bad dstr part"
        end
      end

      if level == :recv
        [fragment("(", sexp), result, fragment(")", sexp)]
      else
        result
      end
    end

    def process_dsym(sexp, level)
      result = []

      sexp.each do |p|
        result << fragment(" + ", sexp) unless result.empty?

        if String === p
          result << fragment(p.inspect, sexp)
        elsif p.first == :evstr
          result << process(s(:call, p.last, :to_s, s(:arglist)), :expr)
        elsif p.first == :str
          result << fragment(p.last.inspect, sexp)
        else
          raise "Bad dsym part"
        end
      end

      [fragment("(", sexp), result, fragment(")", sexp)]
    end

    # s(:if, test, truthy, falsy)
    def process_if(sexp, level)
      test, truthy, falsy = sexp
      returnable = (level == :expr or level == :recv)

      if returnable
        truthy = returns(truthy || s(:nil))
        falsy = returns(falsy || s(:nil))
      end

      # optimize unless (we don't want else unless we need to)
      if falsy and !truthy
        truthy = falsy
        falsy  = nil
        check  = js_falsy test
      else
        check = js_truthy test
      end

      result = [fragment("if (", sexp), check, fragment(") {\n", sexp)]

#      code = "(function() {#{code}}).call(#{current_self})" if returnable
      indent { result.push(fragment(@indent, sexp), process(truthy, :stmt)) } if truthy

      outdent = @indent
      indent { result.push(fragment("\n#{outdent}} else {\n#@indent", sexp), process(falsy, :stmt)) } if falsy

      result << fragment("\n#@indent}", sexp)

      if returnable
        result.unshift fragment("(function() { ", sexp)
        result.push fragment("}).call(#{current_self})", sexp)
      end

      result
    end

    def js_truthy_optimize(sexp)
      if sexp.first == :call
        mid = sexp[2]
        if mid == :block_given?
          return process sexp, :expr
        elsif COMPARE.include? mid.to_s
          return process sexp, :expr
        elsif mid == :"=="
          return process sexp, :expr
        end
      elsif [:lvar, :self].include? sexp.first
        [process(sexp.dup, :expr), fragment(" !== false && ", sexp), process(sexp.dup, :expr), fragment(" !== nil", sexp)]
      end
    end

    def js_truthy(sexp)
      if optimized = js_truthy_optimize(sexp)
        return optimized
      end

      with_temp do |tmp|
        [fragment("(#{tmp} = ", sexp), process(sexp, :expr), fragment(") !== false && #{tmp} !== nil", sexp)]
      end
    end

    def js_falsy(sexp)
      if sexp.first == :call
        mid = sexp[2]
        if mid == :block_given?
          return handle_block_given(sexp, true)
        end
      end

      with_temp do |tmp|
        result = []
        result << fragment("(#{tmp} = ", sexp)
        result << process(sexp, :expr)
        result << fragment(") === false || #{tmp} === nil", sexp)
        result
      end
    end

    # s(:and, lhs, rhs)
    def process_and(sexp, level)
      lhs, rhs = sexp
      t = nil
      tmp = @scope.new_temp

      if t = js_truthy_optimize(lhs)
        result = []
        result << fragment("((#{tmp} = ", sexp) << t
        result << fragment(") ? ", sexp) << process(rhs, :expr)
        result << fragment(" : #{tmp})", sexp)
        @scope.queue_temp tmp

        return result
      end

      @scope.queue_temp tmp

      [fragment("(#{tmp} = ", sexp), process(lhs, :expr), fragment(", #{tmp} !== false && #{tmp} !== nil ? ", sexp), process(rhs, :expr), fragment(" : #{tmp})", sexp)]

    end

    # s(:or, lhs, rhs)
    def process_or(sexp, level)
      lhs = sexp[0]
      rhs = sexp[1]

      with_temp do |tmp|
        lhs = process lhs, :expr
        rhs = process rhs, :expr
        [fragment("(((#{tmp} = ", sexp), lhs, fragment(") !== false && #{tmp} !== nil) ? #{tmp} : ", sexp), rhs, fragment(")", sexp)]
      end
    end

    # s(:yield, arg1, arg2)
    def process_yield(sexp, level)
      call = handle_yield_call sexp, level

      if level == :stmt
        [fragment("if (", sexp), call, fragment(" === __breaker) return __breaker.$v")]
      else
        with_temp do |tmp|
          [fragment("(((#{tmp} = ", sexp), call, fragment(") === __breaker) ? __breaker.$v : #{tmp})", sexp)]
        end
      end
    end

    # special opal yield assign, for `a = yield(arg1, arg2)` to assign
    # to a temp value to make yield expr into stmt.
    #
    # level will always be stmt as its the reason for this to exist
    #
    # s(:yasgn, :a, s(:yield, arg1, arg2))
    def process_yasgn(sexp, level)
      call = handle_yield_call s(*sexp[1][1..-1]), :stmt

      [fragment("if ((#{sexp[0]} = ", sexp), call, fragment(") === __breaker) return __breaker.$v", sexp)]
    end

    # Created by `#returns()` for when a yield statement should return
    # it's value (its last in a block etc).
    def process_returnable_yield(sexp, level)
      call = handle_yield_call sexp, level

      with_temp do |tmp|
        [fragment("return #{tmp} = ", sexp), call,
                    fragment(", #{tmp} === __breaker ? #{tmp} : #{tmp}")]
      end
    end

    def handle_yield_call(sexp, level)
      @scope.uses_block!

      splat = sexp.any? { |s| s.first == :splat }
      sexp.unshift s(:js_tmp, 'null') unless splat    # self
      args = process_arglist sexp, level

      y = @scope.block_name || '__yield'

      if splat
        [fragment("#{y}.apply(null, ", sexp), args, fragment(")", sexp)]
      else
        [fragment("#{y}.call(", sexp), args, fragment(")", sexp)]
      end
    end

    def process_break(sexp, level)
      val = sexp.empty? ? fragment('nil', sexp) : process(sexp.shift, :expr)
      if in_while?
        @while_loop[:closure] ? [fragment("return ", sexp), val, fragment("", sexp)] : fragment("break;", sexp)
      elsif @scope.iter?
        error "break must be used as a statement" unless level == :stmt
        [fragment("return (__breaker.$v = ", sexp), val, fragment(", __breaker)", sexp)]
      else
        error "void value expression: cannot use break outside of iter/while"
      end
    end

    # s(:case, expr, when1, when2, ..)
    def process_case(exp, level)
      pre = []
      code = []
      @scope.add_local "$case"
      expr = process exp.shift, :expr
      # are we inside a statement_closure
      returnable = level != :stmt
      done_else = false

      pre << fragment("$case = ", exp) << expr << fragment(";", exp)

      until exp.empty?
        wen = exp.shift
        if wen and wen.first == :when
          returns(wen) if returnable
          wen = process(wen, :stmt)
          code << fragment("else ", exp) unless code.empty?
          code << wen
        elsif wen # s(:else)
          done_else = true
          wen = returns(wen) if returnable
          code << fragment("else {", exp) << process(wen, :stmt) << fragment("}", exp)
        end
      end

      code << fragment("else { return nil }", exp) if returnable and !done_else

      code.unshift pre

      if returnable
        code.unshift fragment("(function() { ", exp)
        code << fragment("}).call(#{current_self})", exp)
      end

      code
    end

    # when foo
    #   bar
    #
    # s(:when, s(:array, foo), bar)
    def process_when(exp, level)
      arg = exp.shift[1..-1]
      body = exp.shift || s(:nil)
      #body = process body, level if body
      body = process body, level

      test = []
      until arg.empty?
        test << fragment(" || ", exp) unless test.empty?
        a = arg.shift

        if a.first == :splat # when inside another when means a splat of values
          call = s(:call, s(:js_tmp, "$splt[i]"), :===, s(:arglist, s(:js_tmp, "$case")))
          splt = [fragment("(function($splt) { for(var i = 0; i < $splt.length; i++) {", exp)]
          splt << fragment("if (", exp) << process(call, :expr) << fragment(") { return true; }", exp)
          splt << fragment("} return false; }).call(#{current_self}, ", exp)
          splt << process(a[1], :expr) << fragment(")", exp)

          test << splt
        else
          call = s(:call, a, :===, s(:arglist, s(:js_tmp, "$case")))
          call = process call, :expr

          test << call
        end
      end

      [fragment("if (", exp), test, fragment(") {#@space", exp), body, fragment("#@space}", exp)]
    end

    # lhs =~ rhs
    #
    # s(:match3, lhs, rhs)
    def process_match3(sexp, level)
      lhs = sexp[0]
      rhs = sexp[1]
      call = s(:call, lhs, :=~, s(:arglist, rhs))
      process call, level
    end

    # @@class_variable
    #
    # s(:cvar, name)
    def process_cvar(exp, level)
      with_temp do |tmp|
        fragment(("((%s = Opal.cvars[%s]) == null ? nil : %s)" %
          [tmp, exp.shift.to_s.inspect, tmp]), exp)
      end
    end

    # @@name = rhs
    #
    # s(:cvasgn, :@@name, rhs)
    def process_cvasgn(exp, level)
      "(Opal.cvars[#{exp.shift.to_s.inspect}] = #{process exp.shift, :expr})"
    end

    def process_cvdecl(exp, level)
      [fragment("(Opal.cvars[#{exp.shift.to_s.inspect}] = ", exp), process(exp.shift, :expr), fragment(")", exp)]
    end

    # BASE::NAME
    #
    # s(:colon2, base, :NAME)
    def process_colon2(sexp, level)
      base = sexp[0]
      cname = sexp[1].to_s
      result = []

      if @const_missing
        with_temp do |t|
          base = process base, :expr

          result << fragment("((#{t} = (", sexp) << base << fragment(")._scope).", sexp)
          result << fragment("#{cname} == null ? #{t}.cm(#{cname.inspect}) : #{t}.#{cname})", sexp)
        end
      else
        base = process base, :expr

        result <<  fragment("(", sexp) << base << fragment(")._scope.#{cname}", sexp)
      end

      result
    end

    def process_colon3(exp, level)
      with_temp do |t|
        cname = exp.shift.to_s
        fragment("((#{t} = __opal.Object._scope.#{cname}) == null ? __opal.cm(#{cname.inspect}) : #{t})", exp)
      end
    end

    # super a, b, c
    #
    # s(:super, arg1, arg2, ...)
    def process_super(sexp, level)
      args = []
      until sexp.empty?
        args << fragment(", ", sexp) unless args.empty?
        args << process(sexp.shift, :expr)
      end

      js_super [fragment("[", sexp), args, fragment("]", sexp)], sexp
    end

    # super
    #
    # s(:zsuper)
    def process_zsuper(exp, level)
      js_super fragment("__slice.call(arguments)", exp), exp
    end

    def js_super args, sexp
      if @scope.def_in_class?
        mid = @scope.mid.to_s
        sid = "super_#{unique_temp}"

        @scope.uses_super = sid


        [fragment("#{sid}.apply(#{current_self}, ", sexp), args, fragment(")", sexp)]

      elsif @scope.type == :def
        @scope.identify!
        cls_name = @scope.parent.name || "#{current_self}.constructor.prototype"
        jsid     = mid_to_jsid @scope.mid.to_s

        if @scope.defs
          [fragment(("%s._super%s.apply(this, " % [cls_name, jsid]), sexp), args, fragment(")", sexp)]
        else
          [fragment("#{current_self}.constructor._super.prototype#{jsid}.apply(#{current_self}, ", sexp), args, fragment(")", sexp)]
        end

      elsif @scope.type == :iter
        chain, defn, mid = @scope.get_super_chain
        trys = chain.map { |c| "#{c}._sup" }.join ' || '
        [fragment("(#{trys} || #{current_self}.constructor._super.prototype[#{mid}]).apply(#{current_self}, ", sexp), args, fragment(")", sexp)]
      else
        raise "Cannot call super() from outside a method block"
      end
    end

    # a ||= rhs
    #
    # s(:op_asgn_or, s(:lvar, :a), s(:lasgn, :a, rhs))
    def process_op_asgn_or(exp, level)
      process s(:or, exp.shift, exp.shift), :expr
    end

    # a &&= rhs
    #
    # s(:op_asgn_and, s(:lvar, :a), s(:lasgn, :a, rhs))
    def process_op_asgn_and(sexp, level)
      process s(:and, sexp.shift, sexp.shift), :expr
    end

    # lhs[args] ||= rhs
    #
    # s(:op_asgn1, lhs, args, :||, rhs)
    def process_op_asgn1(sexp, level)
      lhs, arglist, op, rhs = sexp

      with_temp do |a| # args
        with_temp do |r| # recv
          args = process arglist[1], :expr
          recv = process lhs, :expr

          aref = s(:call, s(:js_tmp, r), :[], s(:arglist, s(:js_tmp, a)))
          aset = s(:call, s(:js_tmp, r), :[]=, s(:arglist, s(:js_tmp, a), rhs))
          orop = s(:or, aref, aset)

          result = []
          result << fragment("(#{a} = ", sexp) << args << fragment(", #{r} = ", sexp)
          result << recv << fragment(", ", sexp) << process(orop, :expr)
          result << fragment(")", sexp)
          result
        end
      end
    end

    # lhs.b += rhs
    #
    # s(:op_asgn2, lhs, :b=, :+, rhs)
    def process_op_asgn2(sexp, level)
      lhs = process sexp.shift, :expr
      mid = sexp.shift.to_s[0..-2]
      op  = sexp.shift
      rhs = sexp.shift

      if op.to_s == "||"
        with_temp do |temp|
          getr = s(:call, s(:js_tmp, temp), mid, s(:arglist))
          asgn = s(:call, s(:js_tmp, temp), "#{mid}=", s(:arglist, rhs))
          orop = s(:or, getr, asgn)

          [fragment("(#{temp} = ", sexp), lhs, fragment(", ", sexp), process(orop, :expr), fragment(")", sexp)]
        end
      elsif op.to_s == '&&'
        with_temp do |temp|
          getr = s(:call, s(:js_tmp, temp), mid, s(:arglist))
          asgn = s(:call, s(:js_tmp, temp), "#{mid}=", s(:arglist, rhs))
          andop = s(:and, getr, asgn)

          [fragment("(#{temp} = ", sexp), lhs, fragment(", ", sexp), process(andop, :expr), fragment(")", sexp)]
        end
      else
        with_temp do |temp|
          getr = s(:call, s(:js_tmp, temp), mid, s(:arglist))
          oper = s(:call, getr, op, s(:arglist, rhs))
          asgn = s(:call, s(:js_tmp, temp), "#{mid}=", s(:arglist, oper))

          [fragment("(#{temp} = ", sexp), lhs, fragment(", ", sexp), process(asgn, :expr), fragment(")", sexp)]
        end
      end
    end

    # s(:ensure, body, ensure)
    def process_ensure(exp, level)
      begn = exp.shift
      if level == :recv || level == :expr
        retn = true
        begn = returns begn
      end

      result = []
      body = process begn, level
      ensr = exp.shift || s(:nil)
      ensr = process ensr, level

      body = [fragment("try {\n", exp), body, fragment("}", exp)]

      result << body << fragment("#{@space}finally {#@space", exp) << ensr << fragment("}", exp)

      if retn
        [fragment("(function() { ", exp), result, fragment(" }).call(#{current_self})", exp)]
      else
        result
      end
    end

    def process_rescue(exp, level)
      body = exp.first.first == :resbody ? s(:nil) : exp.shift
      body = indent { process body, level }
      handled_else = false

      parts = []
      until exp.empty?
        handled_else = true unless exp.first.first == :resbody
        part = indent { process exp.shift, level }

        unless parts.empty?
          parts << fragment("else ", exp)
        end

        parts << part
      end
      # if no rescue statement captures our error, we should rethrow
      parts << indent { fragment("else { throw $err; }", exp) } unless handled_else

      code = []
      code << fragment("try {#@space#{INDENT}", exp)
      code << body
      code << fragment("#@space} catch ($err) {#@space", exp)
      code << parts
      code << fragment("#@space}", exp)

      if level == :expr
        code.unshift fragment("(function() { ", exp)
        code << fragment(" }).call(#{current_self})", exp)
      end

      code
    end

    def process_resbody(exp, level)
      args = exp[0]
      body = exp[1]

      body = process(body || s(:nil), level)
      types = args[1..-1]
      types.pop if types.last and types.last.first != :const

      err = []
      types.each do |t|
        err << fragment(", ", exp) unless err.empty?
        call = s(:call, t, :===, s(:arglist, s(:js_tmp, "$err")))
        a = process call, :expr
        err << a
      end
      err << fragment("true", exp) if err.empty?

      if Array === args.last and [:lasgn, :iasgn].include? args.last.first
        val = args.last
        val[2] = s(:js_tmp, "$err")
        val = [process(val, :expr) , fragment(";", exp)]
      end

      val = [] unless val

      [fragment("if (", exp), err, fragment("){#@space", exp), val, body, fragment("}", exp)]
    end

    # FIXME: Hack.. grammar should remove top level begin.
    def process_begin(exp, level)
      result = process exp[0], level
    end

    def process_next(exp, level)
      if in_while?
        fragment("continue;", exp)
      else
        result = []
        result << fragment("return ", exp)

        result << (exp.empty? ? fragment('nil', exp) : process(exp.shift, :expr))
        result << fragment(";", exp)

        result
      end
    end

    def process_redo(exp, level)
      if in_while?
        @while_loop[:use_redo] = true
        fragment("#{@while_loop[:redo_var]} = true", exp)
      else
        fragment("REDO()", exp)
      end
    end
  end
end
