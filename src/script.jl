# Scripts: a `.jl` file (or a string of code) compiled to an executable that does what `julia script.jl args...` does.
#
# A script is code that runs from the top, with definitions among it. The definitions (`using`, `import`, `struct`,
# functions, macros, `const`, `include` of another file) and what can be worked out when compiling are done by the compiler,
# in a module of their own: functions, types and constants are what they are in Julia, and values that are made from
# literals are made once, when compiling, and are in the program when it starts. What is left of the script, in order, is the
# body of the function that the program runs, `__script_main__(args)`.
#
# That makes the variables of the script locals of that function, which is what a compiler can make fast, with one
# exception: a variable that a function of the script mentions (a counter, a setting, a cache) is a global of the module, since a
# function can't see the locals of another. (A global that nothing has a type for is slow to call things on, and the compiler
# may not be able to compile what is done with it: `global n::Int` says its type.) `ARGS` is the arguments of the command line;
# `Base.ARGS` is not. `PROGRAM_FILE`, `@__FILE__` and `@__DIR__` are those of the script when it was compiled.
#
# What `evaluate` says about the initial values of variables:
# * `:init` (the default) works out when compiling a variable that is made from literals, collections of them, ranges and
#   comprehensions of them, arithmetic and a few functions of Base that have no effects (`sort`, `Dict`, `string`, ...), for as
#   long as everything before it in the script is that too (the first statement that does anything else, or depends on what is
#   known only when the program runs, ends it, so that what is done at run time is done in the order of the script)
# * `:definitions` does only definitions and `const`.
# `@comptime x = f(3)` makes a statement one that is done when compiling, and `@runtime x = 1` one that is not (they are
# recognized by their names, so a script that has to run in Julia too defines `macro compile_time(ex) esc(ex) end` and `macro runtime(ex) esc(ex) end`).

# the functions of Base that a variable can be made from when compiling: they have no effects, and give what they are given
# whenever they are called. Only where the name is that of Base's function (a script that defines its own `sort` has not).
const SCRIPT_PURE_FUNCTIONS = Set{Symbol}([
    :+, :-, :*, :/, :^, :%, :÷, :&, :|, :⊻, :!, :~, :(==), :(!=), :<, :<=, :>, :>=, :(===), :isequal, :isless, :min, :max, :minmax, :abs, :abs2, :sign,
    :sqrt, :cbrt, :exp, :exp2, :log, :log2, :log10, :sin, :cos, :tan, :asin, :acos, :atan, :sinh, :cosh, :tanh, :floor, :ceil, :round, :trunc, :div, :rem,
    :mod, :fld, :cld, :gcd, :lcm, :hypot, :muladd, :clamp, :length, :size, :ndims, :axes, :eltype, :sum, :prod, :minimum, :maximum, :extrema, :reverse,
    :sort, :unique, :collect, :range, :zeros, :ones, :fill, :Dict, :Set, :Vector, :Matrix, :Array, :String, :string, :Symbol, :Char, :Int, :Int8, :Int16,
    :Int32, :Int64, :Int128, :UInt, :UInt8, :UInt16, :UInt32, :UInt64, :UInt128, :Float16, :Float32, :Float64, :Bool, :Tuple, :NamedTuple, :Pair, :Complex,
    :complex, :Rational, :repeat, :join, :uppercase, :lowercase, :strip, :split, :replace, :first, :last, :get, :haskey, :keys, :values, :zip, :enumerate, :map,
    :filter, :reduce, :foldl, :foldr, :cumsum, :cumprod, :in, :isempty, :count, :any, :all, :ncodeunits, :reshape, :vec, :copy, :identity, :push!, :pop!,
    :getindex, :setindex!, :Ref, :tuple, :vcat, :hcat, :cat, :mapreduce, :findfirst, :findlast, :findall, :isodd, :iseven, :isnan, :isinf, :parse, :tryparse,
    :startswith, :endswith, :occursin, :chomp, :chop, :lstrip, :rstrip, :reverse!, :sort!, :empty!, :append!, :union, :intersect, :setdiff, :diff, :dot,
    :lpad, :rpad, :titlecase, :uppercasefirst, :lowercasefirst, :isdigit, :isletter, :isspace, :isuppercase, :islowercase, :stride, :numerator, :denominator,
])
# (the ones of these that change what they are given: a variable that is made of them is made by working on what the script made)

macro_name(x::Symbol) = x
macro_name(x::GlobalRef) = x.name
macro_name(x::Expr) = x.head === :(.) && length(x.args) == 2 && x.args[2] isa QuoteNode ? x.args[2].value : nothing
macro_name(x) = nothing

mutable struct ScriptLowering
    mod::Module
    evaluate::Symbol
    statements::Vector{Any}              # what is left for the program: `(:run, expr)` and `(:init, name, value)`
    definitions::Vector{Any}             # the definitions of functions, macros and types, for what they mention
    known::Dict{Symbol,Any}              # the variables that were worked out when compiling, and their values
    pure_types::Set{Symbol}              # the types that the script defines that have no constructors of their own
    prefix_open::Bool                    # everything that came before can be worked out when compiling
    main_marker::Bool                    # the script has `@main`
    included::Vector{String}             # the files that were included (to stop an include that includes itself)
end

ScriptLowering(mod::Module, evaluate::Symbol) = ScriptLowering(mod, evaluate, Any[], Any[], Dict{Symbol,Any}(), Set{Symbol}(), true, false, String[])

# whether `ex` has a call of the macro `name` in it
function contains_macro(ex, name::Symbol)
    ex isa Expr || return false
    ex.head === :macrocall && macro_name(ex.args[1]) === name && return true
    return any(a -> contains_macro(a, name), ex.args)
end

# a syntax error of a file that was parsed
function check_syntax(ex, file)
    ex isa Expr || return
    ex.head in (:error, :incomplete) && throw(ArgumentError(string("syntax error in ", file, ": ", ex.args[1] isa Meta.ParseError ? ex.args[1].msg : ex.args[1])))
    for a in ex.args
        check_syntax(a, file)
    end
end

function parse_script(code::AbstractString, file::AbstractString)
    top = Meta.parseall(code; filename = file)
    check_syntax(top, file)
    return top
end

## What is a definition

function is_function_head(lhs)
    lhs isa Expr || return false
    lhs.head === :call && return true
    lhs.head in (:where, :(::)) && return is_function_head(lhs.args[1])
    return false
end

is_definition(ex) = ex isa Expr && (ex.head in (:using, :import, :export, :public, :struct, :abstract, :primitive, :macro, :module, :function, :const, :meta, :latestworld) ||
                                      (ex.head === :(=) && is_function_head(ex.args[1])))

# the names that a signature gives to the arguments of the function
function parameter_names!(set::Set{Symbol}, p)
    p isa Symbol && return push!(set, p)
    p isa Expr || return set
    if p.head === :(::)
        length(p.args) == 2 && parameter_names!(set, p.args[1])
    elseif p.head in (:kw, Symbol("..."))
        parameter_names!(set, p.args[1])
    elseif p.head in (:tuple, :parameters)
        foreach(a -> parameter_names!(set, a), p.args)
    end
    return set
end

function signature_parameters!(set::Set{Symbol}, sig)
    sig isa Expr || return set
    if sig.head in (:where, :(::)) && !(sig.head === :(::) && length(sig.args) == 1)
        return signature_parameters!(set, sig.args[1])
    end
    if sig.head === :call
        sig.args[1] isa Expr && sig.args[1].head === :(::) && parameter_names!(set, sig.args[1]) # (`(x::T)(y)`)
        foreach(a -> parameter_names!(set, a), sig.args[2:end])
    end
    return set
end

# the symbols that are in `ex` as variables (not the names of fields or keywords, which are not), added to `set`
function symbols_of!(set::Set{Symbol}, ex)
    ex isa Symbol && return push!(set, ex)
    ex isa Expr || return set
    if ex.head === :kw
        symbols_of!(set, ex.args[2])
    elseif ex.head === :(.) && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        symbols_of!(set, ex.args[1])
    elseif ex.head === :(=) && is_function_head(ex.args[1])
        foreach(a -> symbols_of!(set, a), ex.args)
    else
        foreach(a -> symbols_of!(set, a), ex.args)
    end
    return set
end

# what a definition mentions of the names that are not its own arguments: the variables of the script that it can read or set
function mentioned_by(def)
    set = Set{Symbol}()
    symbols_of!(set, def)
    own = Set{Symbol}()
    if def isa Expr && (def.head === :function || def.head === :macro || (def.head === :(=) && is_function_head(def.args[1])))
        signature_parameters!(own, def.args[1])
    end
    # (what is `global` in it is the variable of the script, whatever it is called there)
    declared = Set{Symbol}()
    declared_globals!(declared, def)
    return union(setdiff(set, own), declared)
end

# the names that `global` declares anywhere in `ex`
function declared_globals!(set::Set{Symbol}, ex)
    ex isa Expr || return set
    if ex.head === :global
        for a in ex.args
            target = a isa Expr && a.head in (:(=), :(+=), :(-=), :(*=), :(/=), :(^=), :(%=), :(÷=), :(|=), :(&=)) ? a.args[1] : a
            target isa Expr && target.head === :(::) && (target = target.args[1])
            target isa Symbol && push!(set, target)
            target isa Expr && target.head === :tuple && foreach(t -> t isa Symbol && push!(set, t), target.args)
        end
    end
    foreach(a -> declared_globals!(set, a), ex.args)
    return set
end

## The variables of the script

const ASSIGNMENTS = (:(=), :(+=), :(-=), :(*=), :(/=), :(^=), :(%=), :(÷=), :(|=), :(&=), :(<<=), :(>>=), :(⊻=))

function assigned_names!(set::Set{Symbol}, lhs)
    lhs isa Symbol && return push!(set, lhs)
    lhs isa Expr || return set
    if lhs.head === :tuple
        foreach(a -> assigned_names!(set, a), lhs.args)
    elseif lhs.head === :(::)
        assigned_names!(set, lhs.args[1])
    end
    return set
end

# the names that a statement assigns at the top of the script: where it is, and in what is not a scope (`begin`, `if`, `&&`), which
# is not what `for`, `while`, `let`, `try` and functions are
function top_assigned!(set::Set{Symbol}, ex)
    ex isa Expr || return set
    if ex.head in ASSIGNMENTS
        assigned_names!(set, ex.args[1])
        top_assigned!(set, ex.args[2])
    elseif ex.head in (:block, :if, :elseif, :(&&), :(||), :toplevel)
        foreach(a -> top_assigned!(set, a), ex.args)
    elseif ex.head === :global
        foreach(a -> top_assigned!(set, a), ex.args)
        declared_globals!(set, ex)
    end
    return set
end

# the names that are assigned inside what is a scope of its own, other than those that `global` says are the script's
function scoped_assigned!(set::Set{Symbol}, ex)
    ex isa Expr || return set
    ex.head in (:function, :macro, :struct, :(->), :quote) && return set
    if ex.head in ASSIGNMENTS
        is_function_head(ex.args[1]) && return set
        assigned_names!(set, ex.args[1])
        scoped_assigned!(set, ex.args[2])
        return set
    end
    foreach(a -> scoped_assigned!(set, a), ex.args)
    return set
end

# `x = v` in a loop of the script, where `x` is also a variable of the script: in a file Julia makes a variable of the loop (and warns, as it is ambiguous), and here it
# is the variable of the script, as in the REPL and in a function. `scope = :hard` refuses it, as Julia's own rule does not do what the script means.
function check_ambiguous_scope(statements, top::Set{Symbol})
    for (kind, ex) in statements
        kind === :run && ex isa Expr || continue
        # (a statement is kept with its line number: `begin line; statement end`)
        ex.head === :block && length(ex.args) == 2 && ex.args[1] isa LineNumberNode && (ex = ex.args[2])
        ex isa Expr && ex.head in (:for, :while, :let, :try) || continue
        inner = scoped_assigned!(Set{Symbol}(), ex)
        # (not `for i in ...`, whose variable is always a variable of the loop)
        declared = declared_globals!(Set{Symbol}(), ex)
        clash = setdiff(intersect(inner, top), declared)
        isempty(clash) && continue
        throw(ArgumentError(string("a loop at the top of the script assigns the variable", length(clash) > 1 ? "s " : " ", join(("`$s`" for s in sort!(collect(clash))), ", "),
                                   ", which the script has as ", length(clash) > 1 ? "variables" : "a variable", " too: in a file Julia makes ", length(clash) > 1 ? "variables" : "a variable",
                                   " of the loop (and says that it is ambiguous), which `scope = :hard` does not do here. Say `global x` in the loop to set the variable of the script, or use another name.")))
    end
end

# `global x` of a variable that is a local of the program is the variable itself
function strip_globals(ex, locals::Set{Symbol})
    ex isa Expr || return ex
    if ex.head === :global
        kept = Any[]
        assigns = Any[]
        for a in ex.args
            target = a isa Expr && a.head in ASSIGNMENTS ? a.args[1] : a
            if target isa Symbol && target in locals
                a isa Expr && push!(assigns, strip_globals(a, locals))
            else
                push!(kept, a)
            end
        end
        isempty(kept) && isempty(assigns) && return :(nothing)
        isempty(assigns) && return Expr(:global, kept...)
        isempty(kept) && length(assigns) == 1 && return only(assigns)
        parts = Any[Expr(:global, kept...)]
        append!(parts, assigns)
        return Expr(:block, parts...)
    end
    return Expr(ex.head, Any[strip_globals(a, locals) for a in ex.args]...)
end

## What can be worked out when compiling

# a symbol that is a constant (`pi`, `Int`, the `const` of the script)
function script_constant(mod::Module, s::Symbol)
    isdefined(mod, s) && isconst(mod, s) || return false
    v = getglobal(mod, s)
    return !(v isa Function) || (isdefined(Base, s) && getglobal(Base, s) === v && s in SCRIPT_PURE_FUNCTIONS)
end

function script_pure_callee(L::ScriptLowering, f, bound::Set{Symbol})
    if f isa Symbol
        f in bound && return true
        f in L.pure_types && return true
        f in SCRIPT_PURE_FUNCTIONS || (startswith(string(f), ".") && Symbol(string(f)[2:end]) in SCRIPT_PURE_FUNCTIONS) || return false
        base = startswith(string(f), ".") ? Symbol(string(f)[2:end]) : f
        # (the name of Base's function: not one that the script defines with the same name)
        return !isdefined(L.mod, base) || getglobal(L.mod, base) === getglobal(Base, base)
    elseif f isa Expr && f.head === :curly
        return script_pure_callee(L, f.args[1], bound) && all(a -> script_pure(L, a, bound), f.args[2:end])
    end
    return false
end

function generator_binders!(set::Set{Symbol}, spec)
    if spec isa Expr && spec.head === :(=)
        assigned_names!(set, spec.args[1])
    elseif spec isa Expr && spec.head === :filter
        foreach(s -> generator_binders!(set, s), spec.args[2:end])
    end
    return set
end

# whether `ex` is made of literals, the variables that are worked out already, constants and what has no effects of Base
function script_pure(L::ScriptLowering, ex, bound::Set{Symbol} = Set{Symbol}())
    ex isa LineNumberNode && return true
    ex isa Union{Number,AbstractString,Char,Nothing,Bool} && return true
    ex isa QuoteNode && return ex.value isa Union{Symbol,Number,AbstractString,Char,Bool}
    ex isa Symbol && return ex in bound || haskey(L.known, ex) || script_constant(L.mod, ex) || (ex in SCRIPT_PURE_FUNCTIONS && script_pure_callee(L, ex, bound))
    ex isa Expr || return false
    h = ex.head
    if h in (:tuple, :vect, :vcat, :hcat, :row, :ref, :(:), :curly, :string, :block, :if, :elseif, :(&&), :(||), :comparison, :parameters, :kw, :braces)
        return all(a -> script_pure(L, a, bound), ex.args)
    elseif h === :call
        script_pure_callee(L, ex.args[1], bound) || return false
        return all(a -> script_pure(L, a, bound), ex.args[2:end])
    elseif h === :(.)
        # (a field `x.f`, or `f.(x)`)
        if length(ex.args) == 2 && ex.args[2] isa QuoteNode
            return script_pure(L, ex.args[1], bound)
        elseif length(ex.args) == 2 && ex.args[2] isa Expr && ex.args[2].head === :tuple
            return script_pure_callee(L, ex.args[1], bound) && all(a -> script_pure(L, a, bound), ex.args[2].args)
        end
        return false
    elseif h in (:comprehension, :generator, :flatten)
        return script_pure_generator(L, ex, bound)
    elseif h === :(->)
        params = parameter_names!(Set{Symbol}(), ex.args[1])
        return script_pure(L, ex.args[2], union(bound, params))
    end
    return false
end

function script_pure_generator(L::ScriptLowering, ex, bound)
    if ex.head in (:comprehension, :flatten)
        return all(a -> script_pure_generator(L, a, bound), ex.args)
    elseif ex.head === :generator
        binders = Set{Symbol}()
        for spec in ex.args[2:end]
            generator_binders!(binders, spec)
            spec isa Expr && spec.head === :(=) && (script_pure(L, spec.args[2], bound) || return false)
            spec isa Expr && spec.head === :filter && (script_pure(L, spec.args[1], union(bound, binders)) || return false)
        end
        return script_pure(L, ex.args[1], union(bound, binders))
    end
    return script_pure(L, ex, bound)
end

## Lowering

# the statements of the script, in order: what is a definition is done now, and what can be worked out; the rest is kept
function lower_items!(L::ScriptLowering, items, file::String)
    line = LineNumberNode(1, Symbol(file))
    for ex in items
        if ex isa LineNumberNode
            line = ex
            continue
        end
        lower_statement!(L, ex, line, file)
    end
    return L
end

function lower_statement!(L::ScriptLowering, ex, line::LineNumberNode, file::String; expanded::Bool = false)
    ex isa Expr || return # (a number or a string that is alone does nothing)
    if ex.head === :toplevel || (ex.head === :block && !expanded)
        return lower_items!(L, ex.args, file)
    end
    contains_macro(ex, Symbol("@main")) && (L.main_marker = true)
    if ex.head === :macrocall
        name = macro_name(ex.args[1])
        if name === Symbol("@doc") && length(ex.args) >= 3
            return lower_statement!(L, ex.args[end], line, file) # (the documentation is not kept)
        elseif name === Symbol("@comptime") && length(ex.args) >= 3
            return lower_compile_time!(L, ex.args[end], line, file)
        elseif name === Symbol("@runtime") && length(ex.args) >= 3
            return lower_runtime!(L, ex.args[end], line)
        elseif name === Symbol("@main") && length(ex.args) == 2
            return # (the mark, alone: what runs is `main` after the script)
        end
        expanded_ex = Base.invokelatest(macroexpand, L.mod, ex; recursive = true)
        return lower_statement!(L, expanded_ex, line, file; expanded = true)
    end
    # (the macros in what is not a macro call: what is evaluated is what they give)
    if !expanded
        expanded_ex = Base.invokelatest(macroexpand, L.mod, ex; recursive = true)
        expanded_ex isa Expr && expanded_ex.head === :toplevel && return lower_items!(L, expanded_ex.args, file)
        ex = expanded_ex
        ex isa Expr || return
    end
    # `include("file")`: the statements of the file, here
    if ex.head === :call && ex.args[1] === :include && length(ex.args) == 2
        return lower_include!(L, ex.args[2], line, file)
    end
    if is_definition(ex)
        push!(L.definitions, ex)
        if ex.head === :struct
            body = ex.args[3]
            constructors = body isa Expr && any(a -> a isa Expr && (a.head === :function || (a.head === :(=) && is_function_head(a.args[1]))), body.args)
            constructors || push!(L.pure_types, struct_name(ex.args[2]))
        end
        Base.invokelatest(Core.eval, L.mod, ex)
        return
    end
    # `x = v` that can be worked out now
    if L.prefix_open && L.evaluate === :init && lower_initializer!(L, ex)
        return
    end
    L.prefix_open = false
    push!(L.statements, (:run, Expr(:block, line, ex)))
    return
end

function struct_name(head)
    head isa Symbol && return head
    head isa Expr && head.head in (:curly, :(<:)) && return struct_name(head.args[1])
    return :_
end

# `x = v` where `v` is made of what is known: worked out, and kept as a constant of the program
function lower_initializer!(L::ScriptLowering, ex)
    ex isa Expr && ex.head === :(=) && ex.args[1] isa Symbol || return false
    name, rhs = ex.args
    script_pure(L, rhs) || return false
    value = try
        Base.invokelatest(Core.eval, L.mod, rhs)
    catch
        return false # (it throws: that is what the program does when it gets there, and is not what compiling does)
    end
    set_known!(L, name, value)
    return true
end

function set_known!(L::ScriptLowering, name::Symbol, value)
    L.known[name] = value
    # (the module has it too, for what is worked out after it and for the functions that mention it)
    Base.invokelatest(Core.eval, L.mod, Expr(:(=), name, QuoteNode(value)))
    push!(L.statements, (:init, name, value))
    return
end

function lower_compile_time!(L::ScriptLowering, ex, line, file)
    try
        if ex isa Expr && ex.head === :(=) && ex.args[1] isa Symbol
            set_known!(L, ex.args[1], Base.invokelatest(Core.eval, L.mod, ex.args[2]))
        else
            Base.invokelatest(Core.eval, L.mod, ex)
        end
    catch e
        throw(ArgumentError(string("`@comptime` at ", line.file, ":", line.line, " threw when compiling (it can use only what the script has defined or worked out before it, which is what is before the first statement that is done when the program runs): ",
                                   sprint(showerror, e))))
    end
    return
end

function lower_runtime!(L::ScriptLowering, ex, line)
    L.prefix_open = false
    push!(L.statements, (:run, Expr(:block, line, ex)))
    return
end

function lower_include!(L::ScriptLowering, arg, line, file)
    path = Base.invokelatest(Core.eval, L.mod, arg)
    path isa AbstractString || throw(ArgumentError("`include` in the script: the file is not a string ($(repr(path)))"))
    full = isabspath(path) ? String(path) : normpath(joinpath(dirname(file), path))
    isfile(full) || throw(ArgumentError(string("`include(", repr(path), ")` at ", line.file, ":", line.line, ": there is no file ", full)))
    full in L.included && throw(ArgumentError(string("`include(", repr(path), ")` at ", line.file, ":", line.line, " includes a file that is being included: ", full)))
    push!(L.included, full)
    lower_items!(L, parse_script(read(full, String), full).args, full)
    pop!(L.included)
    return
end

"""
    ScriptProgram

What a script becomes (`StaticRuntime.lower_script`): the module that has its definitions, the function that the program runs, and what was decided about its variables:
`globals` (the variables that a function of the script mentions, which are variables of the module), `locals` (the other variables), and `evaluated` (the ones that were worked out when compiling).
"""
struct ScriptProgram
    mod::Module
    main::Function
    globals::Vector{Symbol}
    locals::Vector{Symbol}
    evaluated::Vector{Symbol}
end

function lower_script(code::AbstractString, file::AbstractString; evaluate::Symbol = :init, globals::Symbol = :promote, scope::Symbol = :soft)
    scope in (:soft, :hard) || throw(ArgumentError("`scope` is `:soft` or `:hard`, not `$(repr(scope))`"))
    evaluate in (:init, :definitions) || throw(ArgumentError("`evaluate` is `:init` or `:definitions`, not `$(repr(evaluate))`"))
    globals in (:promote, :error) || throw(ArgumentError("`globals` is `:promote` or `:error`, not `$(repr(globals))`"))
    file = String(file)
    mod = Module(:Script)
    Core.eval(mod, :(global ARGS::Vector{String} = String[]))
    Core.eval(mod, :(const PROGRAM_FILE = $(isfile(file) ? abspath(file) : file)))
    L = ScriptLowering(mod, evaluate)
    isfile(file) && push!(L.included, abspath(file))
    lower_items!(L, parse_script(code, file).args, isfile(file) ? abspath(file) : file)
    # the variables of the script, and which of them a function mentions
    top = Set{Symbol}()
    for s in L.statements
        s[1] === :run && top_assigned!(top, s[2])
        s[1] === :init && push!(top, s[2])
    end
    scope === :hard && check_ambiguous_scope(((s[1], s[2]) for s in L.statements if s[1] === :run), top)
    mentioned = Set{Symbol}()
    for def in L.definitions
        def.head in (:using, :import, :export, :public) && continue
        union!(mentioned, mentioned_by(def))
    end
    shared = sort!(collect(intersect(top, mentioned)))
    if globals === :error && !isempty(shared)
        throw(ArgumentError(string("the variable", length(shared) > 1 ? "s " : " ", join(("`$s`" for s in shared), ", "), " of the script ", length(shared) > 1 ? "are" : "is",
                                   " mentioned by a function of it, which can't see the locals of the program (`globals = :promote` makes them globals of the module)")))
    end
    locals = sort!(collect(setdiff(top, shared)))
    localset = Set{Symbol}(locals)
    # the body of the program: the variables that are worked out are what they were made, and the rest of the statements are what they are
    arg = gensym("args")
    body = Any[Expr(:global, :ARGS, shared...), :(ARGS = $arg)]
    for s in L.statements
        if s[1] === :init
            # (a variable of the module has its value already, and a local of the program has it from here)
            s[2] in localset && push!(body, Expr(:(=), s[2], QuoteNode(s[3])))
        else
            push!(body, strip_globals(s[2], localset))
        end
    end
    if L.main_marker
        push!(body, :(return $(GlobalRef(mod, :main))(ARGS)))
    else
        push!(body, :(return 0))
    end
    Core.eval(mod, Expr(:function, Expr(:call, :__script_main__, Expr(:(::), arg, :(Vector{String}))), Expr(:block, body...)))
    main = Base.invokelatest(getfield, mod, :__script_main__)
    return ScriptProgram(mod, main, shared, locals, sort!(collect(keys(L.known))))
end

"""
    compile_script(path, [dir], [name]; evaluate = :init, globals = :promote, scope = :soft, kwargs...)
    compile_script_string(code, [dir], [name]; filename = "script.jl", kwargs...)

Compile the Julia script in the file `path` (or the code in `code`) to an executable that does what `julia script.jl args...` does, and give the path of it. The program has
`ARGS`, the arguments of the command line. See `docs/src/scripts.md`: what the compiler works out when compiling, and what is left for the program.

`dir` is where the executable is made (the current directory) and `name` its name (that of the file). The other keywords are those of [`compile_executable`](@ref).
"""
function compile_script_string(code::AbstractString, args...; filename::AbstractString = "script.jl", evaluate::Symbol = :init, globals::Symbol = :promote, scope::Symbol = :soft, kwargs...)
    program = lower_script(code, filename; evaluate, globals, scope)
    return compile_script_program(program, filename, args...; kwargs...)
end

function compile_script(path::AbstractString, args...; evaluate::Symbol = :init, globals::Symbol = :promote, scope::Symbol = :soft, kwargs...)
    isfile(path) || throw(ArgumentError("there is no file $path"))
    program = lower_script(read(path, String), path; evaluate, globals, scope)
    return compile_script_program(program, path, args...; kwargs...)
end

function compile_script_program(program::ScriptProgram, file::AbstractString, dir::AbstractString = pwd(), name::AbstractString = first(splitext(basename(file))); kwargs...)
    return Base.invokelatest(compile_executable, program.main, (Vector{String},), String(dir), String(name); kwargs...)
end
