# What is registered: the one place that the packages that are compiled say things to the compiler in, with `add_show_candidates!`, `add_dispatch_candidates!`, `@assume` and `@assume_field`.
#
# The registrations of a process are one value, `REGISTRY`, and they only grow: a type that is registered stays, and a statement of a type that is made again replaces the one before it. Each change
# makes the `version` of the registry a number that no other state of it had, so that two states of the registry are the same if their versions are.
#
# A compilation does not read the registry as it goes (that is the way that what is registered between two compilations can change what the second one is, without the key of what it infers saying so):
# it takes a `Registered`, a copy of what is in the registry when it starts (see `Compilation`), and everything that it asks is asked of that. The functions that Julia generates the code of
# `show_element` and `deepcopy` with read the registry itself: they are made when the code that has them is compiled, and what they are made of is the state that the registry had then.

const SlotKey = Tuple{Symbol,Any,Any} # (the memory of a type of elements, or a field of a struct: see slots.jl)

mutable struct Registry
    show::Vector{Type}                  # the types that `show` of an `Any` (and a call over the registered types) is made over, besides the usual ones
    family::Vector{Type}                # the types that a call is made over only for an argument of a type that they are instances of
    deepcopy::Vector{Any}               # the signatures of the methods of `deepcopy_internal` that are not Base's
    returns::Vector{Tuple{Any,Any}}     # `@assume`: (the signature that a call fits, the type that it gives)
    fields::Dict{SlotKey,Any}           # `@assume_field`: the slot => the type of what is read from it
    embedded::Set{SlotKey}              # `@assume_field_embedded`: the slots that hold only what the objects that are embedded hold
    version::Int
end
Registry() = Registry(Type[], Type[], Any[], Tuple{Any,Any}[], Dict{SlotKey,Any}(), Set{SlotKey}(), 0)

const REGISTRY = Registry()

# (adds `x` to the list, if it is not there: and says whether it was added)
function register_new!(r::Registry, list::Vector, x)
    any(y -> y === x || y == x, list) && return false
    push!(list, x)
    r.version += 1
    return true
end

register_show!(types) = (for T in types; register_new!(REGISTRY, REGISTRY.show, T); end; nothing)
register_family!(types) = (for T in types; register_new!(REGISTRY, REGISTRY.family, T); end; nothing)
register_deepcopy!(sig) = register_new!(REGISTRY, REGISTRY.deepcopy, sig)

# A statement of the type that a call gives replaces the one for the same signature
function register_return!(sig, T)
    for (i, (s, R)) in enumerate(REGISTRY.returns)
        s == sig || continue
        R == T && return false
        REGISTRY.returns[i] = (sig, T)
        REGISTRY.version += 1
        return true
    end
    push!(REGISTRY.returns, (sig, T))
    REGISTRY.version += 1
    return true
end

function register_field!(key::SlotKey, T)
    get(REGISTRY.fields, key, nothing) == T && return false
    REGISTRY.fields[key] = T
    REGISTRY.version += 1
    return true
end

function register_embedded!(key::SlotKey)
    key in REGISTRY.embedded && return false
    push!(REGISTRY.embedded, key)
    REGISTRY.version += 1
    return true
end

"""
    Registered

What was registered when a compilation started (a copy of the `REGISTRY`: see there), with the lists that the compilation asks for already made: the types that a call over `Any` is made over, and the types that `show` is.
"""
struct Registered
    version::Int
    dispatch::Vector{Type}              # the types that a call of an `Any` is made over (not `Vector{Any}`, unless it was registered)
    show::Vector{Type}                  # those of `show`, and `Vector{Any}`
    family::Vector{Type}
    returns::Vector{Tuple{Any,Any}}
    fields::Dict{SlotKey,Any}
    embedded::Set{SlotKey}
end

function Registered(r::Registry = REGISTRY)
    return Registered(r.version,
                      unique!(vcat(DEFAULT_DISPATCH_CANDIDATES, r.show)),
                      unique!(vcat(DEFAULT_SHOW_CANDIDATES, r.show)),
                      copy(r.family), copy(r.returns), copy(r.fields), copy(r.embedded))
end
