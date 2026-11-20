# Overrides for collections and tuples: vector literals, tuple indexing and iteration, `prod`, `splice!`, the element
# types of broadcasts and tuple types, fields of `nothing`, `unsafe_wrap`, `∘`, and `Dict` of pairs of different types.

# `[x, y, ...]` (`Base.vect`) fills the vector with a loop over its arguments, `X[i]`. For arguments of different
# types (an `Any[1, "a"]`) the type of that depends on `i`, which is not known when compiling, so it is a
# dynamic call. Recursing over the arguments gives each its own type.
@device_override function Base.vect(X...)
    isempty(X) && return Vector{Any}()
    a = Vector{Base.promote_typeof(X...)}(undef, length(X))
    vect_fill!(a, 1, X...)
    return a
end

# the same for `Any[x, y, ...]`, which is `getindex(Any, x, y, ...)` (only for `Any`, where the types of the
# elements differ; for the others, Base's method is the one that compiles well)
@device_override function Base.getindex(::Type{Any}, vals...)
    a = Vector{Any}(undef, length(vals))
    vect_fill!(a, 1, vals...)
    return a
end

vect_fill!(a, i) = a

function vect_fill!(a, i, x, xs...)
    @inbounds a[i] = x
    return vect_fill!(a, i + 1, xs...)
end

# `t[i]` of a tuple (and so a loop over one, `iterate`, `collect`, `enumerate`, `Dict(pairs...)`) with an `i` that is
# not known when compiling is `getfield(t, i)`, which for the elements of different types has a type that depends on
# `i`: Julia makes it a call of the runtime that looks the field up and boxes it. One comparison for each element gives
# each its own type, and the result is the union of them, which is split when it is used (as the value of a `Union` is);
# for a constant `i` the comparisons are folded, and for a tuple of one type they are selects. There is a method for
# each number of elements up to 32 (more are `getfield`), written out: a recursion over the tuple is not inlined, and
# then a constant `i` no longer finds the element without making the tuple, which for a type of element that is a
# `Union` is made by the runtime (the `iterate` of an array returns such a tuple, and the element is taken out of it by
# `y[1]`); nor is the method that calls these, unless it is `@inline`. Not a generated function: they can't be inferred
# for a tuple type that is not concrete, as `Tuple{Union{Int,String},Int}`, the type of what `iterate` returns, is not.
@inline tuple_getindex(t::Tuple, i::Int) = getfield(t, i)

for n in 2:32
    pattern = Expr(:curly, :Tuple, ntuple(_ -> :Any, n)...)
    chain = :(throw(BoundsError(t, i)))
    for k in n:-1:1
        chain = :(i == $k ? getfield(t, $k) : $chain)
    end
    @eval @inline tuple_getindex(t::$pattern, i::Int) = $chain
end

@device_override @inline Base.getindex(t::Tuple, i::Int) = tuple_getindex(t, i)

# Base's `iterate` of a tuple is `@nospecialize`d, so it is compiled for any tuple, and its `t[i]` is a `getfield` with
# an index that is not known: for a tuple that has elements stored inline next to ones that are references
# (`Tuple{Int,Any}`, which `string(1, x)` is called with), that is not code that can be made without the runtime. This
# one is specialized for the tuple, and so uses the `getindex` above.
@device_override @inline Base.iterate(t::Tuple, i::Int = 1) = (1 <= i <= length(t)) ? (@inbounds(t[i]), i + 1) : nothing

# The product of a tuple of integers (`length` of an `Array` is `prod(size(a))`) as a loop, with the same result: Base's
# is `*(x...)` and a fold that is written out for up to 32 elements, which for a tuple whose length is not known when
# compiling (`length(::Array{Any})`, of the method of `setindex!` that Base has for an `Array{Any}`, where the code has
# an `Array` whose number of dimensions is not known) is code of 400 statements that Julia's optimizer took more than
# ten seconds over, for each of the two folds. The loop is made into the same code for a tuple whose length is known.
# (Not for the empty tuple, whose type has no `T`: Base's, `prod(()) = 1`.)
@device_override function Base.prod(t::Tuple{T,Vararg{T}}) where {T<:Base.BitInteger}
    p = t[1]
    for i in 2:length(t)
        p *= t[i]
    end
    return p
end

# `splice!` of a vector, written with `deleteat!` and `insert!` (Base's has a tuple of unknown type in it)
@device_override function Base.splice!(a::Vector, i::Integer, ins = Base._default_splice)
    v = a[i]
    deleteat!(a, i)
    k = 0
    for x in ins
        insert!(a, i + k, x)
        k += 1
    end
    return v
end

@device_override function Base.splice!(a::Vector, r::AbstractUnitRange{<:Integer}, ins = Base._default_splice)
    v = a[r]
    deleteat!(a, r)
    k = 0
    for x in ins
        insert!(a, first(r) + k, x)
        k += 1
    end
    return v
end

## The type of the result of a broadcast
#
# `broadcast` makes the array of the result with the type that `Broadcast._bc_eltype` is inferred to return, which Base
# gives as `_broadcast_getindex(inferencebarrier(x), i)::eltype(x)`: the barrier makes `x` a value of the type `Any`,
# and the type assertion is what says what it is. With our compiler an `Any` is closed over the registered types (see
# dispatch.jl), and the assertion keeps what of them is `eltype(x)`: that is `Float64`, `Int` or `Bool`, which are
# registered, but is nothing for `ComplexF64` or `Rational`, which are not, so that the result was inferred to be an
# array of `Union{}` (what `copy` makes when the type is not known) and what used it was a call without a method. The
# matrix is not hidden here: inference of `getindex` of the matrix gives the type itself, and the assertion says it as
# before.
@device_override Base.Broadcast._bc_eltype(x, i) = Base.Broadcast._broadcast_getindex(x, i)::eltype(x)

## `eltype` of a tuple type
#
# `eltype(Tuple{String,String,Int,Int})` (what `eltype` of a `NamedTuple`, and so of the `pairs` of one, is) is
# `Base._compute_eltype`: the join of the types that the tuple has, which Julia finds by running the loop when it is
# inferred (the function is marked as one that is always the same). With the number of types that we split a union in
# (see `SPLIT_LIMIT`) inference does not run it, but follows it, and what it finds is not what the loop gives:
# `Union{Type{String},Type{Union{}}}` for `Tuple{String,String,Int,Int}`, where Julia has `Any`, so that a `Pairs` that
# was made with it had a type that no value has, and the code after it was taken to be unreachable. The answer is a fact
# about the type, so it is given as it is found when compiling, for the type that the tuple is of.
if isdefined(Base, :_compute_eltype)
    @device_override @generated function Base._compute_eltype(t)
        T = t isa DataType && t <: Type && length(t.parameters) == 1 && t.parameters[1] isa Type ? t.parameters[1] : nothing
        T === nothing && return :(Any) # (the type is not known when compiling: `Any` is every eltype's bound)
        return QuoteNode(Base._compute_eltype(T))
    end
end

# A field of `x::Union{Node,Nothing}` (`node.next.value`, `node.next.value = 1`) is an error where `x` is `nothing`.
# `setproperty!` has one method for all types, which finds the type of the field with `fieldtype(typeof(x), f)`: that is
# dynamic for a union, and so is `getfield(x, f)`, which Julia compiles as a call of the runtime. With a method for
# `Nothing` (and `Missing`) the call is split by the type, and each part has a type that is known: the error where it is
# `nothing`, the field where it is a `Node`.
for T in (Nothing, Missing)
    @eval @device_override Base.getproperty(x::$T, f::Symbol) = throw(Base.FieldError($T, f))
    @eval @device_override Base.setproperty!(x::$T, f::Symbol, v) = throw(Base.FieldError($T, f))
end

# `unsafe_wrap(Array, pointer, dims)`: an `Array` over data that the program does not own (what a C library gave), made
# of a `Memory` of that data (`jl_ptr_to_genericmemory`, in the runtime), as Julia's own is made of one in
# `jl_ptr_to_array`, which is not in the binary. The data is never freed with the array (`own = true` is not supported:
# the library that allocated it has the function that frees it).
@device_override function Base.unsafe_wrap(::Union{Type{Array},Type{Array{T}},Type{Array{T,N}}}, p::Ptr{T}, dims::NTuple{N,Int}; own::Bool = false) where {T,N}
    own && error("unsafe_wrap with `own = true` is not supported in compiled programs: free the data with the function of the library that allocated it")
    mem = Base.unsafe_wrap(Memory{T}, p, prod(dims))
    return Base.wrap(Array, mem, dims)
end

@device_override function Base.unsafe_wrap(::Union{Type{Array},Type{Array{T}},Type{Array{T,1}}}, p::Ptr{T}, d::Integer; own::Bool = false) where {T}
    own && error("unsafe_wrap with `own = true` is not supported in compiled programs: free the data with the function of the library that allocated it")
    mem = Base.unsafe_wrap(Memory{T}, p, d)
    return Base.wrap(Array, mem, (Int(d),))
end

## `f ∘ g`
#
# Base calls a `ComposedFunction` through `call_composed(unwrap_composed(c), x...)`, which makes a tuple of the
# functions of a chain and reads them by an index that the compiler does not know (`getfield(fs, i)`, a runtime call).
# The call of the outer function on the result of the inner one is the same, and is what each `ComposedFunction` of a
# chain is.
@device_override (c::ComposedFunction)(x...; kw...) = c.outer(c.inner(x...; kw...))

## `Dict` of pairs of different types
#
# `Dict(:a => 1, :b => "x")`: a `Dict` made of pairs of different types.
#
# Base makes it by going through the pairs as a tuple (`grow_to!`), starting with a `Dict` of the types of the first,
# and, when a pair does not fit, making a `Dict` of the types that are the `promote_typejoin` of those that it has and
# those of the pair, and moving what it has to it. That is a computation with types that Julia does when the program
# runs (`typejoin` of types that are not known when compiling, when the types of the values are a `Union`), which is not
# there. The types of the pairs are known when compiling, so here the same steps are followed with them, in a generated
# function, each one a statement with the types it has. What is made is the same as in Base: the same `Dict` type, and
# the same keys in the same table (the order of iteration depends on how large the table is, which depends on how it was
# made: `sizehint!` for pairs of one type, as `Dict{K,V}(ps)` does, and growing for the others, as `grow_to!` does).

@generated function static_dict_pairs(ps::P) where {P<:Tuple}
    n = isconcretetype(P) ? fieldcount(P) : -1
    n == 0 && return :(Dict{Any,Any}())
    types = n > 0 ? Any[fieldtype(P, i) for i in 1:n] : Any[]
    # (pairs whose types of key and value are not concrete have the types of what they hold only when the program runs:
    # Base's way)
    ok = 1 <= n <= 64 && all(T -> T isa DataType && T <: Pair && isconcretetype(T), types)
    ok || return :(Dict(ps))
    keytypes = Any[T.parameters[1] for T in types]
    valuetypes = Any[T.parameters[2] for T in types]
    statements = Expr[]
    if all(T -> T === types[1], types)
        # `Dict{K,V}(ps)`: one table of the size that is for `n` pairs
        K, V = keytypes[1], valuetypes[1]
        push!(statements, :(d1 = Dict{$K,$V}()), :(sizehint!(d1, $n)))
        for i in 1:n
            push!(statements, :(d1[ps[$i].first] = ps[$i].second))
        end
        return Expr(:block, statements..., :d1)
    end
    # `grow_to!`: a `Dict` of the types of the first pair, which is widened when a pair does not fit
    current = 1
    K, V = keytypes[1], valuetypes[1]
    push!(statements, :(d1 = Dict{$K,$V}()), :(d1[ps[1].first] = ps[1].second))
    for i in 2:n
        dest, next = Symbol(:d, current), Symbol(:d, current + 1)
        if keytypes[i] <: K && valuetypes[i] <: V
            push!(statements, :($dest[ps[$i].first] = ps[$i].second))
        else
            K, V = Base.promote_typejoin(K, keytypes[i]), Base.promote_typejoin(V, valuetypes[i])
            push!(statements, :($next = Dict{$K,$V}()), :(merge!($next, $dest)), :($next[ps[$i].first] = ps[$i].second))
            current += 1
        end
    end
    return Expr(:block, statements..., Symbol(:d, current))
end

@device_override Base.Dict(ps::Pair...) = static_dict_pairs(ps)
