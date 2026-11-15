# What is registered: the one place that the packages that are compiled say things to the compiler in, with `add_show_candidates!`, `add_dispatch_candidates!`, `@assume` and `@assume_field`.
#
# The registrations of a process are one value, `REGISTRY`, and they only grow: a type that is registered stays, and a statement of a type that is made again replaces the one before it. The `version` of the registry is
# a hash of what is in it (not a count of the changes): two states of the registry have the same version if what they have is the same, in whatever order it was registered, and in whatever process, which is what the key
# of what a compilation infers needs of it (see `inference_key`: what was inferred for a version is found by every session that has it, and a session that has another content has another version).
#
# A compilation does not read the registry as it goes (that is the way that what is registered between two compilations can change what the second one is, without the key of what it infers saying so):
# it takes a `Registered`, a copy of what is in the registry when it starts (see `Compilation`), and everything that it asks is asked of that. The functions that Julia generates the code of
# `show_element` and `deepcopy` with read the registry itself: they are made when the code that has them is inferred, and what they are made of is the state that the registry has then. They are made again when what they
# are made for is inferred again, which is whenever the version of the registry is another (it is in the key of what is inferred): what is registered after a program that has them was compiled is what the next one has
# (`test/core/state.jl` compiles one, registers a type, and compiles another).

const SlotKey = Tuple{Symbol,Any,Any} # (the memory of a type of elements, or a field of a struct: see slots.jl)

mutable struct Registry
    show::Vector{Type}                  # the types that `show` of an `Any` (and a call over the registered types) is made over, besides the usual ones
    family::Vector{Type}                # the types that a call is made over only for an argument of a type that they are instances of
    deepcopy::Vector{Any}               # the signatures of the methods of `deepcopy_internal` that are not Base's
    returns::Vector{Tuple{Any,Any}}     # `@assume`: (the signature that a call fits, the type that it gives)
    fields::Dict{SlotKey,Any}           # `@assume_field`: the slot => the type of what is read from it
    embedded::Set{SlotKey}              # `@assume_field_embedded`: the slots that hold only what the objects that are embedded hold
    version::Int                        # a hash of all of the above: see `registry_version`
end
Registry() = Registry(Type[], Type[], Any[], Tuple{Any,Any}[], Dict{SlotKey,Any}(), Set{SlotKey}(), 0)

const REGISTRY = Registry()

# The hash of what the registry has: the sum of the hashes of its parts, so that the order that they were registered in does not matter. (`type_hash`, in compilation.jl, is the same in every process.)
function registry_version(r::Registry)
    h = UInt(0)
    for T in r.show; h += hash(type_hash(T), UInt(1)); end
    for T in r.family; h += hash(type_hash(T), UInt(2)); end
    for sig in r.deepcopy; h += hash(type_hash(sig), UInt(3)); end
    for (sig, R) in r.returns; h += hash(type_hash(R), hash(type_hash(sig), UInt(4))); end
    for ((kind, S, name), T) in r.fields; h += hash(type_hash(T), hash(type_hash(S), hash(name, hash(kind, UInt(5))))); end
    for (kind, S, name) in r.embedded; h += hash(type_hash(S), hash(name, hash(kind, UInt(6)))); end
    return hash(length(r.show) + length(r.family) + length(r.deepcopy) + length(r.returns) + length(r.fields) + length(r.embedded), h) % Int
end

# (adds `x` to the list, if it is not there: and says whether it was added)
function register_new!(r::Registry, list::Vector, x)
    any(y -> y === x || y == x, list) && return false
    push!(list, x)
    r.version = registry_version(r)
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
        REGISTRY.version = registry_version(REGISTRY)
        return true
    end
    push!(REGISTRY.returns, (sig, T))
    REGISTRY.version = registry_version(REGISTRY)
    return true
end

function register_field!(key::SlotKey, T)
    get(REGISTRY.fields, key, nothing) == T && return false
    REGISTRY.fields[key] = T
    REGISTRY.version = registry_version(REGISTRY)
    return true
end

function register_embedded!(key::SlotKey)
    key in REGISTRY.embedded && return false
    push!(REGISTRY.embedded, key)
    REGISTRY.version = registry_version(REGISTRY)
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
