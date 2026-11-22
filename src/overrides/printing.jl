# Output: `print`, `println`, `printf`, `show`, `display`, `sprint`, `repr`, `string` of several values, and color.
#
# Most of it is Base's own code, running on the streams of io.jl. What is here makes the parts that Base resolves at run
# time known when compiling: the names of types and of singletons are constants made by Base's `show`, what a context
# knows of element types is in the stream's type, and values of abstract types are shown over a closed set of types.

## `printf` of StaticTools, to a stream (`printf(fmt, args...)` writes to the standard output, which is
## the same stream as `STDOUT`: both use the buffer of libc, so what they write is in order)

import StaticTools: printf # (to add a method)

printf(io::LibcStream, fmt, args...) = printf(filepointer(io), fmt, args...)

## `print`, `println` and `show` without an `IO` write to the standard output. In Base they use
## `stdout`, Base's global.
##
## An overlay method that covers a call entirely is used *instead of* all the methods of Base,
## also the more specific ones. So these cannot just replace the methods of Base that have
## `stdout` in them, like `print(x1, x2) = print(stdout, x1, x2)`: that would also be used for
## `print(io, x)`, and not use the methods of Base for printing a `String`, a `Char`, ...
## The methods below are written so that they either do what Base does for the calls that have
## an `IO` for the first argument (when that is easy to do exactly), or don't cover them.

# the first argument of calls that have no `IO`, and no output stream: calls with these are
# `print(x1, x2)`, written to the standard output
const Printable = Union{AbstractString, Number, AbstractChar, Symbol, Nothing, Missing, Tuple,
                        AbstractArray, AbstractDict, AbstractSet, Pair, Type, Function, Enum, Ref}

# `print(io, xs...)` of Base, with the loop over the arguments (of different types) unrolled, see
# `print_to_string` in `strings.jl`; more arguments than one: Base's other methods are for one
@device_override function Base.print(io::IO, x1, x2, xs...)
    lock(io)
    print_each(io, x1, x2, xs...)
    unlock(io)
    return nothing
end

# print(x) and print(x1, x2): Base has no other methods with these numbers of arguments that
# are not for an `IO` first, but for `print(x1, x2)` those are many, so only for what is not an `IO`
@device_override Base.print(x) = print(STDOUT, x)

@device_override Base.print(x1::Printable, x2) = print(STDOUT, x1, x2)

@device_override Base.print(x1, x2, x3, xs...) = print_implicit(x1, x2, x3, xs...)

print_implicit(io::IO, xs...) = print(io, xs...)

print_implicit(x, xs...) = print(STDOUT, x, xs...)

# println: Base's `println(io::IO, xs...) = print(io, xs..., "\n")` for an `IO` first
@device_override Base.println() = print(STDOUT, "\n")

@device_override Base.println(x) = println_implicit(x)

@device_override Base.println(x1, x2) = println_implicit(x1, x2)

@device_override Base.println(x1, x2, x3, xs...) = println_implicit(x1, x2, x3, xs...)

println_implicit(io::IO) = print(io, "\n")

println_implicit(io::IO, xs...) = print(io, xs..., "\n")

println_implicit(x) = print(STDOUT, x, "\n")

println_implicit(x, xs...) = print(STDOUT, x, xs..., "\n")

@device_override Base.show(x) = show(STDOUT, x)

## Printing several values to a string

# `print_to_string(xs...)`, which `string`, error messages and `sprint`-like helpers use, loops
# over its arguments as `for i in 1:nfields(xs); print(s, xs[i]); end`. When the arguments have
# different types, the type of `xs[i]` depends on `i`, which is not known when compiling, so every
# call becomes a dynamic dispatch. Recursing over the tuple gives each element its own type.
@device_override function Base.print_to_string(xs...)
    isempty(xs) && return ""
    s = IOBuffer(sizehint = sizehint_sum(xs...))
    print_each(BufIO(s), xs...) # (a `BufIO`: the methods of `show` below are for it)
    return Base.takestring!(s)
end

sizehint_sum() = 0

sizehint_sum(x, xs...) = Base._str_sizehint(x) + sizehint_sum(xs...)

print_each(s) = nothing

function print_each(s, x, xs...)
    print(s, x)
    return print_each(s, xs...)
end

# `string(1, x)` (and so `"a=$(1) b=$(x)"`) where `x` is not known when compiling (a value of `Any`): the arguments are
# a `Tuple{Int,Any}`, which is not a concrete type (the type of the tuple depends on `x`), so making it, and taking an
# element of it, is a call of the runtime. With the arguments one by one it is not made. (Without an `Any` in them the
# methods of Base are used as they were: those for strings and characters are more specific.)
for n in 2:12
    args = [Symbol(:x, i) for i in 1:n]
    @eval @device_override function Base.string($(args...))
        s = IOBuffer()
        io = BufIO(s) # (the methods of `show` below are for a `BufIO`, as in `print_to_string` above)
        $([:(print(io, $a)) for a in args]...)
        return Base.takestring!(s)
    end
end

## `sprint(f, args...)` (and `repr(x)`, which is `sprint(show, x)`) writes to a `BufIO` instead of an `IOBuffer`, with
## the context that the keyword `context` gives it: the properties of another stream (they are copied), or a `Pair` or a
## tuple of them

# (a method for each of the usual numbers of arguments, and not only `args...`: `args` is a tuple of the types of the
# arguments, and for an argument of the type `Any` (an element of a `Vector{Any}`, whose `alignment` is `sprint(show,
# x)`) it is a `Tuple{Any}`, whose layout is not known: the argument is taken out of it by a call of the runtime. An
# argument of its own is a value of the type `Any`, which is a call that is resolved over the registered types.)
for n in 0:3
    xs = [Symbol(:x, i) for i in 1:n]
    @eval @device_override Base.@constprop :aggressive @inline function Base.sprint(f::Function, $(xs...); context=nothing, sizehint::Integer=0)
        s = IOBuffer(sizehint=sizehint)
        f(sprint_context(BufIO(s), context), $(xs...))
        return Base.takestring!(s)
    end
end

@device_override Base.@constprop :aggressive @inline function Base.sprint(f::Function, args...; context=nothing, sizehint::Integer=0)
    s = IOBuffer(sizehint=sizehint)
    f(sprint_context(BufIO(s), context), args...)
    return Base.takestring!(s)
end

# `repr(x; context = :compact => true)` is Base's own method, which calls `sprint`: the pair is a constant where `repr`
# is called, and is not one in a method that is not inlined (the type of the stream is made from it)
@device_override Base.@constprop :aggressive @inline Base.repr(x; context=nothing) = sprint(show, x; context=context)

# (`@constprop :aggressive`: the properties are constants where `sprint` is called, and have to be known here to make
# the type of the stream)
sprint_context(io::BufIO, ::Nothing) = io

sprint_context(io::BufIO, ::Union{LibcStream,BufIO}) = io

sprint_context(io::BufIO, ::IOBuffer) = io # (a buffer as the context, as `alignment` gives it: it has no properties)

# (a context that Base made of a buffer, `IOContext(io, :color => false)`: what `alignment` of a number gives `sprint`.
# Its properties are in a dictionary that has them when the program runs, and are not in its type, so they are not used:
# `:color` is false for a stream that is written to a string, as it is here)
sprint_context(io::BufIO, ::Base.IOContext{IOBuffer}) = io

sprint_context(io::BufIO, context::ContextIO) = IOContext(io, context)

Base.@constprop :aggressive @inline sprint_context(io::BufIO, context::Pair) = IOContext(io, context)

Base.@constprop :aggressive @inline sprint_context(io::BufIO, context::Tuple) = IOContext(io, context...)

## `show`
#
# Base's `show` for a container asks the `IOContext` of the stream what the type of the elements already is
# (`:typeinfo`), and prints type names by looking at modules and bindings. That is all dynamic. Here both are known when
# compiling:
#
# * the name of a type `T` is a constant string, made by Base's own `show` when compiling, so that it is exactly what
#   Base prints;
# * what the context knows about the type of the elements is in the type of the stream (`ContextIO`, in io.jl),
#   and what Base does with it (`typeinfo_prefix`) is done when compiling, for the type of the container.

Base.show_circular(::ShowStream, @nospecialize(x)) = false

## Names of types

# The text that Base's `show` makes for what is shown to a stream (as `stdout`, for which the types of `Main` are not
# written with their module), made when compiling (`host_text`). Base's `show` writes `Main.Pt` where it writes `Pt` for
# the program; the `Main.` is dropped. (Types of other modules that the program makes visible with `using` or `import`
# (`Diagonal` of `LinearAlgebra`) do get their module: a difference with Base.)
host_string(f, x) = replace(sprint(f, x; context = :module => Main), r"(?<![\w.])Main\." => "")

# What the generators below put in the code they make, in place of the text itself: a call that inference makes when
# compiling (its arguments are constants), in the world of the compilation (see `abstract_call_known` for `host_text` in
# dispatch.jl). A generator runs in the world of its own definition, in which the methods that a package defines after
# this one is loaded are not there, and printing a type can need them (`Indicator{ACTIVATE_ON_ONE}` of MathOptInterface
# prints the value of its `@enum` with the `namemap` that the package defines): what a generator printed itself was an
# error there. (This method is what the call is in Julia: it gives the same text.)
host_text(f, x) = host_string(f, x)

# In the program, where the call is not folded because the type is not known when compiling (a type that is a value: an element
# of a `Vector{Type}`, one of a union of types), the text of a type is in the table that the linker makes (`runtime_type_text`),
# and what `host_string` would be is not compiled: it is Julia's `sprint` and `show` of a type, `show_datatype` and
# `show_typeparams` and all that they call, which a program does not have. (Folded where the type is known: see `host_text` in
# dispatch.jl.)
@device_override host_text(f, x) = f === show ? runtime_show_text(x) : host_string(f, x)
runtime_show_text(x::DataType) = runtime_type_text(x)
runtime_show_text(x) = x isa DataType ? runtime_type_text(x) : error("the text of what is not a type that is known when compiling is not made when the program runs")

type_name(::Type{T}) where {T} = host_text(show, T)

Base.show(io::ShowStream, ::Type{T}) where {T} = (print(io, type_name(T)); nothing)

# (an `IOBuffer` is a stream that a program makes itself, as `summary` does: the name of the type is the same)
Base.show(io::Base.GenericIOBuffer, ::Type{T}) where {T} = (print(io, type_name(T)); nothing)

# A type that is a value when the program runs, and not a constant where it is printed (`string(typeof(x))` of an `x` of
# a union, the elements of a tuple of types, `map(typeof, args)` in a message): the methods above are compiled for any
# `T` there, which is found when the program runs (a call of the runtime). The text of each type that is in the binary
# is in a table that the linker makes (`define_type_name_table!` in runtime/types.jl), with what Julia's `show` gives
# it, as `host_text` does for a constant: `static_type_name` finds it. The compiler calls this in place of those methods
# for such a type (`abstract_call_known` for `show` in dispatch.jl).
function runtime_type_text(T::DataType)
    p = @symbolcall static_type_name(pointer_from_objref(T)::Ptr{Cvoid})::Ptr{UInt8}
    p == C_NULL && return String(T.name.name) # (a type that is not in the binary: no program has one)
    return unsafe_string(p)
end

show_type_value(io::IO, T::DataType) = (print(io, runtime_type_text(T)); nothing)

## Singletons: functions, `Colon()`, ...
##
## What Base prints for a value that has no fields depends on its type only (the name of the function, and the module
## if it is not visible from where it is shown), but it finds that out with lookups of modules and bindings, in
## libjulia. The text is made when compiling (as for the names of types).

@generated singleton_text(::Type{T}) where {T} = Base.issingletontype(T) ? :(host_text(show, $(QuoteNode(T.instance)))) : nothing

function Base.show(io::ShowStream, f::Function)
    text = singleton_text(typeof(f))
    text === nothing && return @invoke Base.show(io::IO, f::Function)
    print(io, text)
    return nothing
end

function Base.print(io::ShowStream, f::Function)
    text = singleton_text(typeof(f))
    text === nothing && return @invoke Base.print(io::IO, f::Function)
    print(io, text)
    return nothing
end

Base.show(io::ShowStream, ::Colon) = (print(io, "Colon()"); nothing)

## `typeinfo_prefix` of Base, which prefixes what is shown by the type of the container when the context
## doesn't know the type of the elements. It depends on the types only, and on whether the container is empty.

# `_typeinfo_implicit` of Base finds the method in the latest world: dynamic. The answer depends on the
# type only
@generated function static_implicit(::Type{T}) where {T}
    return Base.typeinfo_implicit(T)
end

@device_override Base._typeinfo_implicit(::Type{T}) where {T} = static_implicit(T)

@generated function typeinfo_prefix_static(::Type{TI}, X::XT) where {TI,XT}
    typeinfo = XT <: TI ? TI : Any
    eltype_ctx = Base.typeinfo_eltype(typeinfo)
    eltype_X = eltype(XT)
    # the strings that Base makes, for the container being empty and not
    if XT <: AbstractDict
        full = :(host_text(print, $XT))
        name = :(host_text(Base.show_type_name, $(QuoteNode(XT.name))))
        if eltype_X == eltype_ctx
            return :(($name, false))
        else
            implicit = Base._typeinfo_implicit(keytype(XT)) && Base._typeinfo_implicit(valtype(XT))
            return implicit ? :(isempty(X) ? ($full, false) : ($name, true)) : :(($full, false))
        end
    elseif eltype_X == eltype_ctx
        return :(("", false))
    else
        implicit = Base.typeinfo_implicit(eltype_X)
        text = Base.print_without_params(eltype_X) ?
            :(host_text(Base.show_type_name, $(QuoteNode(Base.unwrap_unionall(eltype_X).name)))) : :(host_text(print, $eltype_X))
        return implicit ? :(isempty(X) ? ($text, false) : ("", true)) : :(($text, false))
    end
end

# (what it is, as in Base: a stream whose type is not known, as in the code of `sprint` for a context that is not a
# constant, has it of the type `Any` without this, and then `show` of a vector to it is `Union{}`, wider than nothing,
# and the result of `sprint` with the context that is a constant was discarded for being wider than that: `repr(v;
# context = :compact => true)`)
Base.typeinfo_prefix(io::ShowStream, X) = typeinfo_prefix_static(typeinfo_of(io), X)::Tuple{String,Bool}

## `Symbol`s

# Base decides how a `Symbol` is written (`:name`, an operator, `Symbol("a b")`) with the tables of the parser, which
# are in libjulia. A name that is a plain ASCII identifier is `:name`, as in Base. For the other symbols that are in the
# binary the text is what Julia writes, which is made when linking (`define_symbol_texts!`); of those that the program
# makes, the names that are certainly not identifiers or operators are `Symbol("...")`, and for any other it's an error,
# as printing it differently from Base would be wrong
function Base.show(io::ShowStream, s::Symbol)
    if symbol_is_plain(s)
        print(io, ':', string(s))
        return nothing
    end
    text = symbol_text(s)
    if text != 0
        unsafe_write(io, Ptr{UInt8}(text), UInt(@symbolcall strlen(Ptr{UInt8}(text)::Ptr{UInt8})::Int64))
    elseif symbol_is_certainly_quoted(s)
        print(io, "Symbol(")
        show(io, string(s))
        print(io, ')')
    else
        error("show: a Symbol that the program made, and that is not an ASCII identifier, is not supported")
    end
    return nothing
end

# A name in code (`Base.show_sym`: a field of a `NamedTuple`, a name in an expression): the name itself, or `var"..."`.
# Base decides with the tables of the parser too. The text of each symbol of the binary that is not a plain ASCII name,
# and of the keywords (`var"true"`), is made when linking (`define_symbol_names!`), as for `show`; a plain name that is
# not there is itself. (So a keyword that only the program makes, `Symbol("true")` in a program that has no `:true`, is
# written as it is, where Base writes `var"true"`.)
@device_override function Base.show_sym(io::IO, sym::Symbol; allow_macroname = false)
    text = symbol_text(sym, embedded_symbol_names())
    if text != 0
        unsafe_write(io, Ptr{UInt8}(text), UInt(@symbolcall strlen(Ptr{UInt8}(text)::Ptr{UInt8})::Int64))
    elseif symbol_is_plain(sym)
        unsafe_write(io, symbol_pointer(sym), UInt(symbol_length(sym)))
    elseif symbol_is_certainly_quoted(sym)
        print(io, "var\"", Base.escape_raw_string(string(sym)), '"')
    else
        error("show: a Symbol that the program made, and that is not an ASCII identifier, is not supported")
    end
    return nothing
end

## Elements of an abstract type: dispatch over a closed set of types
##
## `show(io, x)` of an `x` of the type `Any` (an element of a `Vector{Any}`) is a dynamic call in Julia. When
## compiling, only a closed set of the types is known to be possible, and the call is a chain of `isa`
## (tests of the type tag of `x`) over that set. What is not in the set is not known, which can not
## be reported when compiling, so what is not in the set is an error when the program runs. Add types with
## `add_show_candidates!`.

const DEFAULT_SHOW_CANDIDATES = Type[Int, Float64, String, Bool, Char, Symbol, Nothing,
    Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128, Float16, Float32,
    Missing, Vector{Any}]

"""
    add_show_candidates!(types...)

Add concrete types to those that `show` of a value of an abstract type (an element of a `Vector{Any}`, say) dispatches
over in compiled code, besides the defaults (numbers, `String`, `Char`, `Symbol`, `Nothing`, `Missing`, `Vector{Any}`):
`add_show_candidates!(MyType, Tuple{Int,Float64})`. A value of another type is an error when the program runs. Call it
before compiling. (It is a list, not a method to add, because the dispatch is made in the world age of `show_element`,
where methods defined later are not visible.)
"""
function add_show_candidates!(types::Type...)
    for T in types
        isconcretetype(T) || throw(ArgumentError("$T is not a concrete type"))
    end
    register_show!(types)
    return nothing
end

@generated function show_element(io, x, ::Type{T}) where {T}
    isconcretetype(T) && return :(show(io, x); nothing)
    body = Expr(:block)
    for C in vcat(DEFAULT_SHOW_CANDIDATES, REGISTRY.show) # (the registry as it is when this is generated: see registry.jl)
        typeintersect(C, T) === Union{} && continue
        # (an `isa` that is true when `T` is a subtype of `C`: no test)
        push!(body.args, :(x isa $C && return (show(io, x::$C); nothing)))
    end
    push!(body.args, :(error("show: a value of a type that is not in the list of `add_show_candidates!`")))
    return body
end

## Containers

# the elements of a tuple, each with the type that the tuple has for it
@generated function Base.show(io::ShowStream, t::T) where {T<:Tuple}
    TI = typeinfo_type(io)
    n = fieldcount(T)
    body = Expr(:block, :(print(io, '(')))
    for i in 1:n
        i > 1 && push!(body.args, :(print(io, ", ")))
        typeinfo = (T <: TI && TI <: Tuple && fieldcount(TI) >= i) ? fieldtype(TI, i) : TI
        push!(body.args, :(show_element(typeinfo_io(io, $typeinfo), t[$i], $(fieldtype(T, i)))))
    end
    n == 1 && push!(body.args, :(print(io, ',')))
    push!(body.args, :(print(io, ')')), :(nothing))
    return body
end

## `Pair`: `a => b`, or `Pair{K,V}(a, b)` when the context doesn't make the types clear (as in Base: see `show` for
## a `Pair` there), with each of the parts shown with the type that the pair has for it

@generated function Base.show(io::ShowStream, p::P) where {P<:Pair}
    isconcretetype(P) || return :(error("show: the type of a pair is not known when compiling"))
    K, V = P.parameters
    TI = typeinfo_type(io)
    # a pair is `delimited` (shown with its type) if it isn't of the types of its parts, and the context doesn't have
    # its type (`has_tight_type` of Base compares types with `==`, which is a call of libjulia: `===` is the same for
    # these)
    tight = isconcretetype(K) && isconcretetype(V) ? true : :(typeof(p.first) === $K && typeof(p.second) === $V)
    delimited = (tight === true || TI == P) ? false : :(!$tight)
    infos = (P <: TI && TI <: Pair) ? (fieldtype(TI, 1), fieldtype(TI, 2)) : (Any, Any)
    parts = Expr(:block)
    for (i, (name, T)) in enumerate(((:first, K), (:second, V)))
        # (a part of an abstract type is not known to be a pair, and is delimited)
        isdelimited = isconcretetype(T) ? :(Base.isdelimited(io_i, x)) : true
        push!(parts.args, quote
            io_i = typeinfo_io(io, $(infos[i]))
            x = p.$name
            d = $isdelimited
            d || print(io, "(")
            show_element(io_i, x, $T)
            d || print(io, ")")
            $(i == 1 ? :(print(io, " => ")) : :nothing)
        end)
    end
    return quote
        if $delimited
            Base.show_pairtyped(io, p)
        else
            $parts
        end
        nothing
    end
end

## Structs: `show_default` of Base, `Name(field, field, ...)`, with the type name and the types of the fields known
## when compiling (a field of an abstract type is shown with `show_element`)

@generated function Base.show_default(io::ShowStream, x::T) where {T}
    isconcretetype(T) || return :(error("show: the type of a value is not known when compiling"))
    isprimitivetype(T) && return :(error("show: a primitive type needs a method of `show`"))
    body = Expr(:block, :(print(io, host_text(show, $T), '(')))
    n = fieldcount(T)
    for i in 1:n
        i > 1 && push!(body.args, :(print(io, ", ")))
        push!(body.args, :(if isdefined(x, $i)
            show_element(typeinfo_io(io, Any), getfield(x, $i), $(fieldtype(T, i)))
        else
            print(io, Base.undef_ref_str)
        end))
    end
    push!(body.args, :(print(io, ')')), :(nothing))
    return body
end

## Arrays of more than one dimension

# Base shows a matrix with `_show_nonempty(io, inferencebarrier(X), ...)`, which makes the matrix a value of the type
# `Any` for the compiler (so that the code is compiled once for all arrays, and not for each type of them): a dynamic
# call. The same without the barrier.
@device_override Base.show_nd(io::IO, a::AbstractArray, print_matrix::Function, show_full::Bool) =
    Base._show_nd(io, a, print_matrix, show_full, map(Base.unitrange, axes(a)))

@device_override Base._show_nonempty(io::IO, X::AbstractMatrix, prefix::String) = Base._show_nonempty(io, X, prefix, false, axes(X))

@device_override function Base._show_nonempty(io::IO, X::AbstractArray, prefix::String)
    print(io, prefix)
    Base.show_nd(io, X, (io, slice) -> Base._show_nonempty(io, slice, prefix, true, axes(slice)), false)
end

## `text/plain`: `display`, and the alignment of what is in a matrix

# `display(x)` of Julia shows `x` with the first of the displays that can: with nothing else, the `TextDisplay` of the
# standard output, which writes the `text/plain` form of `x` and a newline. (The list of displays is a `Vector` of an
# abstract type, which can't be resolved when compiling.)
@device_override Base.display(@nospecialize x) = (show(STDOUT, MIME"text/plain"(), x); println(STDOUT); nothing)

# `print_matrix` makes the matrix a value of the type `Any` for the compiler (`inferencebarrier`), as `show` does (see
# above)
@device_override Base.print_matrix(io::IO, X::AbstractVecOrMat, pre::AbstractString = " ", sep::AbstractString = "  ", post::AbstractString = "",
                                   hdots::AbstractString = "  \u2026  ", vdots::AbstractString = "\u22ee", ddots::AbstractString = "  \u22f1  ",
                                   hmod::Integer = 5, vmod::Integer = 5) =
    Base._print_matrix(io, X, pre, sep, post, hdots, vdots, ddots, hmod, vmod, Base.unitrange(axes(X, 1)), Base.unitrange(axes(X, 2)))

# Base lines up the numbers in a column on their decimal points (`1.5` and `22.25`), by finding where the part before
# the point ends in what `show` writes, with a regular expression, for a `Real`, a `Complex` and a `Rational`. There is
# no `Regex` in a compiled program, so the same is found with a scan of the text. (`alignment(io, x::Integer)` and the
# other methods are Base's.) Each is what the regular expression of Base matches, in the comment.

# `^(.*?)((?:[\.eEfF].*)?)$`: up to the first `.`, `e`, `E`, `f` or `F`, and the rest
@device_override function Base.alignment(io::IO, x::Real)
    s = sprint(show, x, context = Base.nocolor(io), sizehint = 0)
    i = findfirst(c -> c in ".eEfF", s)
    i === nothing && return (textwidth(s), 0)
    return (textwidth(SubString(s, 1, prevind(s, i))), textwidth(SubString(s, i)))
end

# `^(.*[^ef][\+\-])(.*)$`: up to the last `+` or `-` that has a character before it that is not `e` or `f` (the sign of
# the imaginary part, and not that of an exponent), and the rest
@device_override function Base.alignment(io::IO, x::Complex)
    s = sprint(show, x, context = Base.nocolor(io), sizehint = 0)
    i = findlast(c -> c in "+-", s)
    while i !== nothing
        j = prevind(s, i)
        j >= firstindex(s) && !(s[j] in "ef") && return (textwidth(SubString(s, 1, i)), textwidth(SubString(s, nextind(s, i))))
        i = i == firstindex(s) ? nothing : findprev(c -> c in "+-", s, prevind(s, i))
    end
    return (textwidth(s), 0)
end

# `^(.*?/)(/.*)$`: up to and with the first of the two slashes of the first `//`, and the rest
@device_override function Base.alignment(io::IO, x::Rational)
    s = sprint(show, x, context = Base.nocolor(io), sizehint = 0)
    i = findfirst("//", s)
    i === nothing && return (textwidth(s), 0)
    return (textwidth(SubString(s, 1, first(i))), textwidth(SubString(s, last(i))))
end

# The placeholder that structured matrices (`Diagonal`, `UpperTriangular`, ...) show for the elements that are not
# stored (`⋅`) is as wide as what would have been there: Base measures that with `textwidth(ANSIIterator(s))`, which
# skips the codes of colors with a regular expression. The streams here have no colors, so it is the width of `s`.
@device_override function Base.replace_with_centered_mark(s::AbstractString; c::AbstractChar = '⋅')
    N = textwidth(s)
    return N == 0 ? string(c) : join(setindex!([" " for i in 1:N], string(c), ceil(Int, N / 2)))
end

## Colors and styles
#
# Base keeps the sequences in two `Dict`s (`text_colors`, `disable_text_style`), which are objects of the Julia that
# compiles, so `output_color_string` is written here with the sequences as constants: a chain of comparisons of the
# symbol (as for `namedtuple_get`), which for a color that is known when compiling is folded.
#
# Whether the standard output has color is not known when compiling, and a program that is not told is as `julia
# script.jl > file`: it has none. `Base.get_have_color()` (which Crayons, and so UnicodePlots, ask for what `get(io,
# :color, ...)` does not say) is `false`, and a stream has color when its context says so: `IOContext(STDOUT, :color =>
# true)`.

const TEXT_COLORS = (
    :black => "\e[30m", :red => "\e[31m", :green => "\e[32m", :yellow => "\e[33m", :blue => "\e[34m", :magenta => "\e[35m", :cyan => "\e[36m", :white => "\e[37m",
    :light_black => "\e[90m", :light_red => "\e[91m", :light_green => "\e[92m", :light_yellow => "\e[93m", :light_blue => "\e[94m", :light_magenta => "\e[95m",
    :light_cyan => "\e[96m", :light_white => "\e[97m", :normal => "\e[0m", :default => "\e[39m", :bold => "\e[1m", :italic => "\e[3m", :underline => "\e[4m",
    :blink => "\e[5m", :reverse => "\e[7m", :hidden => "\e[8m", :nothing => "",
)

const DISABLE_TEXT_STYLE = (:bold => "\e[22m", :italic => "\e[23m", :underline => "\e[24m", :blink => "\e[25m", :reverse => "\e[27m", :hidden => "\e[28m",
                            :normal => "", :default => "", :nothing => "")

@generated function symbol_text(::Val{table}, name::Symbol, default::String) where {table}
    chain = :default
    for (key, value) in reverse(collect(getfield(@__MODULE__, table)))
        chain = :(name === $(QuoteNode(key)) ? $value : $chain)
    end
    return chain
end

# the sequence of a color (a name, or a number of the 256: `"\e[38;5;Nm"`), which is `:default` if there is none, as in
# Base
color_escape(color::Symbol) = symbol_text(Val(:TEXT_COLORS), color, "\e[39m")

color_escape(color::Int) = 0 <= color <= 255 ? string("\e[38;5;", color, "m") : "\e[39m"

disable_escape(color::Symbol) = symbol_text(Val(:DISABLE_TEXT_STYLE), color, "\e[39m")

disable_escape(color::Int) = "\e[39m"

@device_override function Base.output_color_string(buf::IOBuffer, str::String, @nospecialize(color::Union{Int, Symbol}),
        bold::Bool, italic::Bool, underline::Bool, blink::Bool, reverse::Bool, hidden::Bool)
    bold && color === :bold && (color = :nothing)
    italic && color === :italic && (color = :nothing)
    underline && color === :underline && (color = :nothing)
    blink && color === :blink && (color = :nothing)
    reverse && color === :reverse && (color = :nothing)
    hidden && color === :hidden && (color = :nothing)
    enable_ansi = string(color_escape(color), bold ? "\e[1m" : "", italic ? "\e[3m" : "", underline ? "\e[4m" : "", blink ? "\e[5m" : "", reverse ? "\e[7m" : "", hidden ? "\e[8m" : "")
    disable_ansi = string(hidden ? "\e[28m" : "", reverse ? "\e[27m" : "", blink ? "\e[25m" : "", underline ? "\e[24m" : "", bold ? "\e[22m" : "", italic ? "\e[23m" : "", disable_escape(color))
    first = true
    for line in eachsplit(str, '\n')
        first || print(buf, '\n')
        first = false
        isempty(line) && continue
        print(buf, enable_ansi, line, disable_ansi)
    end
    return takestring!(buf)
end

@device_override Base.get_have_color() = false

# Whether the terminal has 24-bit color is asked when the program runs, of the environment as Base asks it
# (`ttyhastruecolor`) except for the terminfo of the terminal: the variables `COLORTERM`, `VTE_VERSION`,
# `XTERM_VERSION`, `TERMINAL_PROGRAM`, `KONSOLE_*` and `TERM`. (A terminal that says only in its terminfo is taken to
# have 256 colors.)
@device_override function Base.get_have_truecolor()
    get(ENV, "COLORTERM", "") in ("truecolor", "24bit") && return true
    something(tryparse(Int, get(ENV, "VTE_VERSION", "")), 0) >= 3600 && return true
    (haskey(ENV, "XTERM_VERSION") || haskey(ENV, "KONSOLE_PROFILE_NAME") || haskey(ENV, "KONSOLE_DBUS_SESSION")) && return true
    get(ENV, "TERMINAL_PROGRAM", "") == "iTerm.app" && return true
    term = get(ENV, "TERM", "")
    return startswith(term, "linux") || startswith(term, "rxvt") || startswith(term, "st")
end

# `printstyled` of a stream, and without one (that is `stdout`). The method for a stream is Base's `printstyled(io::IO,
# msg...)`, which `printstyled(msg...)` here would replace (a method of our table is the one that is called, whatever
# the other methods are), so it is written out, as `print_implicit` is for `print`.
@device_override Base.printstyled(msg...; kwargs...) = printstyled_implicit(msg...; kwargs...)

printstyled_implicit(io::IO, msg...; bold::Bool=false, italic::Bool=false, underline::Bool=false, blink::Bool=false, reverse::Bool=false, hidden::Bool=false, color::Union{Int,Symbol}=:normal) =
    Base.with_output_color(print, color, io, msg...; bold=bold, italic=italic, underline=underline, blink=blink, reverse=reverse, hidden=hidden)

printstyled_implicit(msg...; kwargs...) = printstyled_implicit(STDOUT, msg...; kwargs...)

## Annotated strings
#
# Base prints an `AnnotatedString` with `ansi_write_`, which calls `ansi_write` (that StyledStrings has methods of, for
# the styles) in the world of the running task (`invoke_in_world`), which is a call that the program makes when it runs.
# A program is made with the methods that there are when compiling: the call is made directly.
@device_override Base.AnnotatedDisplay.ansi_write_(f::Function, io::IO, @nospecialize(x)) = Base.AnnotatedDisplay.ansi_write(f, io, x)

@device_override Base.AnnotatedDisplay.show_annot_(io::IO, @nospecialize(x)) = (Base.AnnotatedDisplay.show_annot(io, x); nothing)

@device_override Base.AnnotatedDisplay.show_annot_(io::IO, m::MIME, @nospecialize(x)) = (Base.AnnotatedDisplay.show_annot(io, m, x); nothing)

# `annotatedstring(xs...)` (what `styled"..."` with interpolation, `join`, `*` and `repeat` of annotated strings make)
# goes through the arguments with a loop over a tuple of values of different types, that asks `x isa
# SubString{<:AnnotatedString}` of each: with the type of the element not known, that makes a type when the program
# runs. It is a call for each argument (the type of each is known), and an annotation is made from its parts, as `(;
# label, value)` is not for a value of the type `Any`.
@device_override function Base.annotatedstring(xs...)
    isempty(xs) && return Base.AnnotatedString("")
    buf = IOBuffer()
    s = IOContext(buf, :color => true)
    annotations = Vector{Base.RegionAnnotation}()
    add_annotated!(s, buf, annotations, xs...)
    return Base.AnnotatedString(takestring!(buf), annotations)
end

add_annotated!(s, buf, annotations) = nothing

function add_annotated!(s, buf, annotations, x::Base.AnnotatedString, rest...)
    size = buf.size
    for annot in x.annotations
        push!(annotations, Base.RegionAnnotation((annot.region .+ size, annot.label, annot.value)))
    end
    print(s, x.string)
    add_annotated!(s, buf, annotations, rest...)
end

function add_annotated!(s, buf, annotations, x::SubString{<:Base.AnnotatedString}, rest...)
    size = buf.size
    for annot in x.string.annotations
        start, stop = first(annot.region), last(annot.region)
        if start <= x.offset + x.ncodeunits && stop > x.offset
            rstart = size + max(0, start - x.offset - 1) + 1
            rstop = size + min(stop, x.offset + x.ncodeunits) - x.offset
            push!(annotations, Base.RegionAnnotation((rstart:rstop, annot.label, annot.value)))
        end
    end
    print(s, Base.unannotate(x))
    add_annotated!(s, buf, annotations, rest...)
end

function add_annotated!(s, buf, annotations, x::Base.AnnotatedChar, rest...)
    size = buf.size
    for annot in x.annotations
        push!(annotations, Base.RegionAnnotation((1+size:1+size, annot.label, annot.value)))
    end
    print(s, x.char)
    add_annotated!(s, buf, annotations, rest...)
end

function add_annotated!(s, buf, annotations, x, rest...)
    print(s, x)
    add_annotated!(s, buf, annotations, rest...)
end
