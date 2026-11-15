# Types that are stated, and not found: `@assume f(::A, ::B)::R` says that the call of `f` with arguments of these types (or subtypes) gives a value of the type `R`, and `@assume_field S.name::T` that the field `name` of
# a struct of the type `S` holds a value of the type `T`.
#
# Much of what code from a package has to be written again for (an override that is a copy of a function, with a type put in it) is a type that the compiler does not find: `theme(nothing, :SSAO)` is a `Union` of
# `Nothing`, `Attributes`, `Observable` and others, and what is done with it is a call that is made for each of them, though the code knows that it is an `Attributes`. A statement of the type is one line, and is
# not a copy of the code that may change: the call is the one of the package, and where its type is wider than what is stated the program is checked.
#
# * For a return: when a method that the signature fits is inferred, what it gives is the type that is stated where inference found more (the intersection of the two; the type itself if they have nothing in common),
#   and every `return` of the code of the method is `typeassert`ed to it, so that the callers (and the code that has the method inlined) have a type that is right, or a program that stops with a type error
#   that says what it was. The method is inferred as it is, and the check is in what it returns.
# * For a field: what is read from it is of the type, in the code that reads it, as for the types that the slots hold (slots.jl), and the read is `typeassert`ed.
#
# What is stated has to be given where the module is initialized (`__init__`), as `add_dispatch_candidates!` is: the registry (registry.jl) is of the session, and is not kept by what is precompiled. A compilation takes
# a copy of it when it starts (`Compilation.registered`: the signatures as `Tuple` types that start with the type of the function, with the type that each gives; the slots, with the type of what is read from each; and the slots
# that hold what the objects that are embedded hold), and what it infers is kept apart for the version of the registry that it had, as for the types that are registered.

"""
    StaticRuntime.assume_return!(signature::Type{<:Tuple}, T)

What `@assume` does: the calls that `signature` fits (`Tuple{typeof(f), A, B}` for `f(::A, ::B)`) give a value of the type `T`.
"""
function assume_return!(@nospecialize(sig), @nospecialize(T))
    sig isa Type && sig <: Tuple || throw(ArgumentError("the signature of an assumption is a `Tuple` type that starts with the type of the function, not $(repr(sig))"))
    T isa Type || throw(ArgumentError("the type that is assumed is a type, not $(repr(T))"))
    register_return!(sig, T)
    return nothing
end

"""
    StaticRuntime.assume_field!(S::DataType, name::Symbol, T)

What `@assume_field` does: the field `name` of a struct of the type `S` holds a value of the type `T`.
"""
function assume_field!(@nospecialize(S), name::Symbol, @nospecialize(T))
    S isa DataType && isconcretetype(S) && isstructtype(S) || throw(ArgumentError("`$(repr(S))` is not a struct that fields can be assumed of"))
    hasfield(S, name) || throw(ArgumentError("`$S` has no field `$name`"))
    T isa Type || throw(ArgumentError("the type that is assumed is a type, not $(repr(T))"))
    register_field!((:field, S, name), T)
    return nothing
end

"""
    StaticRuntime.assume_field_embedded!(S::DataType, name::Symbol)

What `@assume_field_embedded` does: the field `name` of a struct of the type `S` holds what the objects that are in the program as constants hold (and what the code stores in it of a type that is known).
"""
function assume_field_embedded!(@nospecialize(S), name::Symbol)
    S isa DataType && isconcretetype(S) && isstructtype(S) || throw(ArgumentError("`$(repr(S))` is not a struct that fields can be assumed of"))
    hasfield(S, name) || throw(ArgumentError("`$S` has no field `$name`"))
    register_embedded!((:field, S, name))
    return nothing
end

# the arguments of a call that is written with types: `f(::A, x::B, y)` is `(A, B, Any)`
function assumption_argument_types(args)
    types = Any[]
    for a in args
        if a isa Expr && a.head === :(::)
            push!(types, a.args[end])
        elseif a isa Symbol
            push!(types, :Any)
        else
            throw(ArgumentError("an assumption has arguments with types (`::A`, `x::A`) or names: `$a` is not one"))
        end
    end
    return types
end

"""
    @assume f(::A, ::B)::R
    @assume Module.f(::A)::R

State that the call of `f` with arguments of the types `A` and `B` (or subtypes) gives a value of the type `R`, where inference finds a wider type (a `Union`, `Any`). The method that is called is inferred as it is,
and what it returns is checked: a program in which it gives another type stops with a type error. Use it where the module is initialized (`__init__`), as with `add_dispatch_candidates!`. A function with keyword
arguments is stated by its method without them (`Core.kwcall`), and a type that is made, `T(...)`, by `Type{T}`.

```julia
function __init__()
    StaticRuntime.@assume Makie.theme(::Nothing, ::Symbol)::Attributes
end
```
"""
macro assume(ex)
    ex isa Expr && ex.head === :(::) && length(ex.args) == 2 && ex.args[1] isa Expr && ex.args[1].head === :call ||
        throw(ArgumentError("`@assume` is given a call with the type that it gives: `@assume f(::A, ::B)::R`"))
    call, R = ex.args
    f = call.args[1]
    argtypes = assumption_argument_types(call.args[2:end])
    return :($assume_return!(Tuple{$Core.Typeof($(esc(f))), $(map(esc, argtypes)...)}, $(esc(R))))
end

"""
    @assume_field S.name::T

State that the field `name` of a struct of the type `S` holds a value of the type `T` (where it is of the type `Any` or another that is not concrete). What is read from it has that type, and the read is
checked. Use it where the module is initialized (`__init__`).
"""
macro assume_field(ex)
    ex isa Expr && ex.head === :(::) && length(ex.args) == 2 && ex.args[1] isa Expr && ex.args[1].head === :. && ex.args[1].args[2] isa QuoteNode ||
        throw(ArgumentError("`@assume_field` is given a field with its type: `@assume_field S.name::T`"))
    field, T = ex.args
    return :($assume_field!($(esc(field.args[1])), $(field.args[2]), $(esc(T))))
end

"""
    @assume_field_embedded S.name

State that the field `name` of a struct of the type `S` holds only what the objects that the program has as constants hold at the time of compiling (the state that is made by running the initialization of a package, and
embedded), and what the code stores in it of a type that is known. A store of a value of a type that is not known (a function that sets a field by its name, `setproperty!(x, ::Symbol, ::Any)`) does not count, which
is what makes the type of the field known; what is read from the field is checked, so that a program in which it holds another type stops with a type error that says so. Use it where the module is initialized (`__init__`).
"""
macro assume_field_embedded(ex)
    ex isa Expr && ex.head === :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode ||
        throw(ArgumentError("`@assume_field_embedded` is given a field: `@assume_field_embedded S.name`"))
    return :($assume_field_embedded!($(esc(ex.args[1])), $(ex.args[2])))
end

# the type that a method is assumed to give (the one of all the assumptions that fit it): the specialization `mi` is one that a signature fits when its types are subtypes of that signature
function assumed_return(c::Compilation, mi::Core.MethodInstance)
    returns = c.registered.returns
    isempty(returns) && return nothing
    found = nothing
    for (sig, R) in returns
        mi.specTypes <: sig || continue
        found = found === nothing ? R : typeintersect(found, R)
    end
    return found
end

# the type that inference gives, as the type that is assumed where it is wider
function assumed_result(@nospecialize(found), @nospecialize(R))
    found isa CC.LimitedAccuracy && return found
    w = CC.widenconst(found)
    (w === Union{} || w <: R) && return found
    narrowed = typeintersect(w, R)
    return narrowed === Union{} ? R : narrowed
end

function CC.finishinfer!(me::CC.InferenceState, interp::OverridesInterpreter, cycleid::Int, opt_cache::IdDict{Core.MethodInstance,Core.CodeInstance})
    R = assumed_return(compilation(), me.linfo)
    R === nothing || (me.bestguess = assumed_result(me.bestguess, R))
    return @invoke CC.finishinfer!(me::CC.InferenceState, interp::CC.AbstractInterpreter, cycleid::Int, opt_cache::IdDict{Core.MethodInstance,Core.CodeInstance})
end

# every `return` of the method gives a value of the type that is assumed (a `typeassert` where the code does not know it)
function assert_assumed_returns!(c::Compilation, ir::CC.IRCode, mi::Core.MethodInstance)
    R = assumed_return(c, mi)
    R === nothing && return ir
    changed = false
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Core.ReturnNode && isdefined(st, :val) || continue
        w = CC.widenconst(CC.argextype(st.val, ir))
        (w === Union{} || w <: R) && continue
        checked = CC.insert_node!(ir, pc, CC.NewInstruction(Expr(:call, Core.typeassert, st.val, R), R), false)
        ir.stmts[pc][:stmt] = Core.ReturnNode(checked)
        changed = true
    end
    return changed ? CC.compact!(ir) : ir
end
