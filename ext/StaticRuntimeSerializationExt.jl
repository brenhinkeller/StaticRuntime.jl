# Serialization: `serialize` of values whose types the compiler knows.
#
# What `serialize` writes of a type or a module (its name, the path of its module, the UUID of the package) is found by the
# runtime of Julia (`ijl_module_uuid`, the table of packages). For a type that is known when compiling, these are known
# when compiling: the code that writes the type is made for each type (a `Val` of it, as `serialize_type_data` of Julia's
# is for any), and the bytes of the module are a constant (the names are symbols, which have no back references). What is
# kept of the stream is as it is in Julia: the table of the objects that were written, and the numbers of the back
# references, so the bytes are the same.
module StaticRuntimeSerializationExt

using StaticRuntime: StaticRuntime, @device_override
using Serialization: Serialization, Serializer

# `serialize_mod_names(s, m)` for the module `m`, as the writing of its parts: the UUID of the package and the name, and the
# names of the modules below it. (The names are symbols, and a long one is kept in the table of what has been written, so that
# the second time it is a back reference: they are written by `serialize`, and not as bytes.)
function mod_names_code(m::Module)
    p = parentmodule(m)
    if p === m || m === Base
        key = Base.root_module_key(m)
        uuid = key.uuid
        return Any[:(Serialization.serialize(s, $(uuid === nothing ? nothing : uuid.value))),
                   :(Serialization.serialize(s, $(QuoteNode(Symbol(key.name)))))]
    end
    return Any[mod_names_code(p)..., :(Serialization.serialize(s, $(QuoteNode(nameof(m)))))]
end

@generated function serialize_mod_names_of(s::Serializer, ::Val{M}) where {M}
    return Expr(:block, mod_names_code(M)..., nothing)
end

@device_override @inline Serialization.serialize_mod_names(s::Serializer, m::Module) = serialize_mod_names_of(s, Val(m))

# `serialize(s, m)` of a module
@device_override @inline function Serialization.serialize(s::Serializer, m::Module)
    Serialization.writetag(s.io, Serialization.MODULE_TAG)
    serialize_mod_names_of(s, Val(m))
    Serialization.writetag(s.io, Serialization.EMPTYTUPLE_TAG)
end

# the module of a type, written as the code of `serialize(s, m)`
module_code(m::Module) = quote
    Serialization.writetag(s.io, Serialization.MODULE_TAG)
    serialize_mod_names_of(s, Val($(QuoteNode(m))))
    Serialization.writetag(s.io, Serialization.EMPTYTUPLE_TAG)
end

# `serialize_type_data(s, T)` for the type `T` (written as the code that Julia's makes of it, with what is known of `T`)
function type_data_code(T::DataType)
    Serialization.should_send_whole_type(nothing, T) && return :(Serialization.serialize_type_data(s, $(QuoteNode(T))))
    iswrapper = T === Base.unwrap_unionall(T.name.wrapper)
    body = Expr(:block)
    push!(body.args, :(Serialization.serialize_cycle(s, $(QuoteNode(T))) && return nothing))
    push!(body.args, :(Serialization.writetag(s.io, Serialization.DATATYPE_TAG)))
    push!(body.args, :(Serialization.serialize(s, $(QuoteNode(nameof(T))))))
    push!(body.args, module_code(parentmodule(T)))
    if !isempty(T.parameters)
        if iswrapper
            push!(body.args, :(write(s.io, Int32(0))))
        else
            push!(body.args, :(write(s.io, Int32($(length(T.parameters))))))
            for p in T.parameters
                push!(body.args, :(Serialization.serialize(s, $(QuoteNode(p)))))
            end
        end
    end
    push!(body.args, nothing)
    return body
end

@generated function serialize_type_data_of(s::Serializer, ::Val{T}) where {T}
    return type_data_code(T)
end

@generated function serialize_type_of(s::Serializer, ::Val{T}, ref::Bool) where {T}
    tag = Serialization.sertag(T)
    tag > 0 && return :(Serialization.writetag(s.io, $tag); nothing)
    return quote
        Serialization.writetag(s.io, ref ? Serialization.REF_OBJECT_TAG : Serialization.OBJECT_TAG)
        serialize_type_data_of(s, Val($(QuoteNode(T))))
    end
end

@generated function serialize_datatype_of(s::Serializer, ::Val{T}) where {T}
    tag = Serialization.sertag(T)
    tag > 0 && return :(Serialization.write_as_tag(s.io, $tag))
    T === Tuple && return :(Serialization.write_as_tag(s.io, Serialization.TUPLE_TAG))
    return :(serialize_type_data_of(s, Val($(QuoteNode(T)))))
end

@device_override @inline Serialization.serialize_type(s::Serializer, t::DataType, ref::Bool = false) = serialize_type_of(s, Val(t), ref)
@device_override @inline Serialization.serialize(s::Serializer, t::DataType) = serialize_datatype_of(s, Val(t))

# (`typeof(x)` has to be known: without `@nospecialize`, which the methods of Julia's have)
@device_override @inline function Serialization.serialize_cycle_header(s::Serializer, x)
    Serialization.serialize_cycle(s, x) && return true
    Serialization.serialize_type(s, typeof(x), true)
    return false
end

# `sertag(v)`: the tag of the objects that Julia's has one for (types, symbols, small integers, modules, functions), which it finds
# in a table that is hashed by `objectid` (the addresses of the objects that the compiling Julia has: not those of the program).
# Here it is the objects of the type of `v` that have a tag, compared one after the other (`===`).
const SERTAG_KEYS = Any[k for k in Serialization.TAGS[1:Serialization.NSERTAG_KEYS]]

@generated function sertag_of(v::T) where {T}
    keys = [k for k in SERTAG_KEYS if !isconcretetype(T) || typeof(k) === T]
    chain = :(Int32(-1))
    for k in reverse(keys)
        tag = Serialization.sertag(k)
        tag > 0 || continue
        chain = :(v === $(QuoteNode(k)) ? Int32($tag) : $chain)
    end
    return chain
end

@device_override @inline Serialization.sertag(v) = sertag_of(v)

# The table of the objects that are written (`cycle_table`) has keys that hold any object (an `IdKey`), whose `objectid` has
# to be for any type of value: a program that has not been told the types that they have stops (no method of
# `static_objectid`). What the table looks at is whether it is the same object, so the address of it is hashed.
@device_override Base.hash(k::Serialization.IdKey, h::UInt) = hash(UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), k.val)), h)

# the fields of an object of the type `T` (a loop over them, which Julia's has, is not unrolled: `isdefined(x, i)` for a number
# that is not known is a call of the runtime)
@generated function serialize_fields(s::Serializer, x::T) where {T}
    body = Expr(:block)
    for i in 1:fieldcount(T)
        push!(body.args, quote
            if isdefined(x, $i)
                Serialization.serialize(s, getfield(x, $i))
            else
                Serialization.writetag(s.io, Serialization.UNDEFREF_TAG)
            end
        end)
    end
    push!(body.args, nothing)
    return body
end

@device_override function Serialization.serialize_any(s::Serializer, x)
    tag = Serialization.sertag(x)
    if tag > 0
        return Serialization.write_as_tag(s.io, tag)
    end
    t = typeof(x)::DataType
    if isprimitivetype(t)
        Serialization.serialize_type(s, t)
        write(s.io, x)
    else
        if ismutable(x)
            Serialization.serialize_cycle(s, x) && return
            Serialization.serialize_type(s, t, true)
        else
            Serialization.serialize_type(s, t, false)
        end
        serialize_fields(s, x)
    end
    nothing
end


## Reading
#
# `deserialize` makes the value that the stream says: a value of a type that the stream names, which the program does not
# know. A program is made for its types, so what is read is one of the types that the program has: those that it
# serializes (it notes them: `note_type(:deserialize, T)`, here and in what a type holds) and those that were registered
# (`add_deserialize_types!`). `deserialize(s)` is `call_over_noted(:deserialize, read_noted, s)`, which is made over the
# union `All` of them, and what it gives is a value of one of the types of `All`, as the compiler sees it (a union that
# Julia splits). A stream of a type that is not in it stops the program with a message.
#
# The reader is the one of Julia's, for the types of `All` (`handle_deserialize`, as the code of each type): a tag says what
# comes next, a type is read as a description (what the module and the name of it are, and its parameters) which is found
# in the table of the types, as a hash of it that is made when compiling, and the value of the type is read as the code of
# the type says (the fields of a struct one after the other, the elements of an array, the pairs of a `Dict`). The back
# references of the stream (objects that came before, the types and the long symbols) are kept as Julia's reader keeps them.

const H_TAG = 0x5bd1e9955bd1e995
const H_DT = 0x9e3779b97f4a7c15
const H_SYM = 0xc2b2ae3d27d4eb4f
const H_MOD = 0x165667b19e3779f9
const H_INT = 0x27d4eb2f165667c5
const H_PARAM = 0x85ebca6b2545f491
const H_UN = 0xff51afd7ed558ccd

@inline mix(h::UInt64, x::UInt64) = (h ⊻ x) * 0x100000001b3
@inline mix(h::UInt64, x::Integer) = mix(h, UInt64(x % UInt64))

# the hash of the text of a name, as the bytes are read from a stream
function sym_hash(str::AbstractString)
    h = H_SYM
    for b in codeunits(str)
        h = mix(h, UInt64(b))
    end
    return mix(h, UInt64(ncodeunits(str)))
end

# the hash of the path of a module (what `serialize_mod_names` writes: the UUID of the package or nothing, the name of it, and
# the names below it)
function mod_hash(m::Module)
    p = parentmodule(m)
    if p === m || m === Base
        key = Base.root_module_key(m)
        uuid = key.uuid
        h = H_MOD
        if uuid === nothing
            h = mix(h, UInt64(0))
        else
            h = mix(mix(mix(h, UInt64(1)), UInt64(uuid.value % UInt64)), UInt64((uuid.value >> 64) % UInt64))
        end
        return mix(h, sym_hash(String(Symbol(key.name))))
    end
    return mix(mod_hash(p), sym_hash(String(nameof(m))))
end

# the hash of the description of a type, as `serialize` writes it, and the parameters that it has (types, integers, symbols,
# booleans and tuples of them); `nothing` for a type that has one that is not (a `Union`, a `UnionAll`)
function type_hash_of(T::Union)
    a = type_hash_of(T.a)
    b = type_hash_of(T.b)
    (a === nothing || b === nothing) && return nothing
    return mix(mix(H_UN, a), b)
end

function type_hash_of(T::DataType)
    tag = Serialization.sertag(T)
    tag > 0 && return mix(H_TAG, tag)
    T === Tuple && return mix(H_TAG, Serialization.TUPLE_TAG)
    h = mix(mix(H_DT, sym_hash(String(nameof(T)))), mod_hash(parentmodule(T)))
    if !isempty(T.parameters)
        if T === Base.unwrap_unionall(T.name.wrapper)
            h = mix(h, 0)
        else
            h = mix(h, length(T.parameters))
            for p in T.parameters
                ph = param_hash_of(p)
                ph === nothing && return nothing
                h = mix(h, ph)
            end
        end
    end
    return h
end

function param_hash_of(@nospecialize(p))
    if p isa DataType || p isa Union
        return type_hash_of(p)
    elseif p isa Bool
        return mix(H_PARAM, p ? 2 : 1)
    elseif p isa Int
        return mix(mix(H_INT, 3), p)
    elseif p isa Symbol
        return mix(mix(H_PARAM, 4), sym_hash(String(p)))
    elseif p isa Tuple
        h = mix(mix(H_PARAM, 5), length(p))
        for x in p
            ph = param_hash_of(x)
            ph === nothing && return nothing
            h = mix(h, ph)
        end
        return h
    end
    return nothing
end

## what can be read

# the types that are read as a number (by the tag of the stream)
const NUMBER_TYPES = Type[Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Int128, UInt128, Float16, Float32, Float64, Char]

is_array_type(T) = T isa DataType && T <: Array
is_dict_type(T) = T isa DataType && T <: Dict
is_tuple_type(T) = T isa DataType && T <: Tuple && T !== Tuple{}
is_struct_type(T) = T isa DataType && isconcretetype(T) && !isprimitivetype(T) && !is_array_type(T) && !is_dict_type(T) && !is_tuple_type(T) &&
                    T !== String && T !== Nothing && T !== Tuple{} && T !== Symbol && T !== BigInt && !(T <: Function) && !(T <: Core.Builtin) &&
                    !(T <: AbstractString) && type_hash_of(T) !== nothing

# whether a value of the type can be read
function readable(T)
    T isa DataType || return false
    isconcretetype(T) || return false
    T in NUMBER_TYPES && return true
    (T === Bool || T === Nothing || T === String || T === Tuple{}) && return true
    is_array_type(T) && return type_hash_of(T) !== nothing
    is_dict_type(T) && return type_hash_of(T) !== nothing
    is_tuple_type(T) && return true
    return is_struct_type(T)
end

# the types of everything that a value of the type holds that is concrete (for the types that a program notes): what a
# value of the type is made of, and that can be read
function noted_closure!(out::Vector{Type}, @nospecialize(T), depth::Int = 0)
    depth > 8 && return out
    T isa Type || return out
    if T isa Union
        for U in Base.uniontypes(T)
            noted_closure!(out, U, depth + 1)
        end
        return out
    end
    T isa DataType && isconcretetype(T) || return out
    T in out && return out
    readable(T) || return out
    push!(out, T)
    if is_array_type(T)
        noted_closure!(out, T.parameters[1], depth + 1)
    elseif is_dict_type(T)
        noted_closure!(out, T.parameters[1], depth + 1)
        noted_closure!(out, T.parameters[2], depth + 1)
    elseif is_tuple_type(T)
        for p in T.parameters
            noted_closure!(out, p, depth + 1)
        end
    elseif is_struct_type(T)
        for i in 1:fieldcount(T)
            noted_closure!(out, fieldtype(T, i), depth + 1)
        end
    end
    return out
end


## the tags that the reader looks at

const TAGS = Serialization.TAGS
const VALUE_TAGS = Serialization.VALUE_TAGS
const LITERAL_SYMBOL_HASHES = UInt64[(i >= VALUE_TAGS && TAGS[i] isa Symbol) ? sym_hash(String(TAGS[i])) : UInt64(0) for i in 1:length(TAGS)]
const LITERAL_IS_SYMBOL = Bool[i >= VALUE_TAGS && TAGS[i] isa Symbol for i in 1:length(TAGS)]
const TAG_IS_TYPE = Bool[TAGS[i] isa Type && (i < Serialization.o0 || i >= VALUE_TAGS) && i != Serialization.sertag(Symbol) for i in 1:length(TAGS)]
# (a backreference to what a description of a type, or a symbol, was)
struct TypeEntry; h::UInt64; end
struct SymEntry; h::UInt64; end

# (a program that stops with an exception does not say what it was: what is wrong is written first)
@noinline function reader_error(parts...)
    print(StaticRuntime.STDERR, "deserialize: ", parts..., "\n")
    error("deserialize: ", parts...)
end
@noinline stream_error(b::Integer) = reader_error("the stream has a value (tag ", Int(b), ") that is not of a type that the program has; `StaticRuntime.add_deserialize_types!` adds types")
@noinline unknown_type(h::UInt64) = reader_error("the stream has a value of a type that the program does not have (hash ", h, "); `StaticRuntime.add_deserialize_types!` adds types")
@noinline bad_stream(what::String) = reader_error(what)

@inline next_tag(s) = Int32(read(s.io, UInt8)::UInt8)

## descriptions of types, in the stream

# the hash of a name (a symbol): `b` is its tag, which is read
function read_symbol_hash(s::Serializer, b::Int32)::UInt64
    if b == Serialization.SYMBOL_TAG || b == Serialization.LONGSYMBOL_TAG
        len = b == Serialization.SYMBOL_TAG ? Int(read(s.io, UInt8)::UInt8) : Int(read(s.io, Int32)::Int32)
        h = H_SYM
        for _ in 1:len
            h = mix(h, UInt64(read(s.io, UInt8)::UInt8))
        end
        h = mix(h, UInt64(len))
        if len > 7
            slot = s.counter
            s.counter += 1
            Serialization._setbackref!(s, slot, SymEntry(h))
        end
        return h
    elseif b >= VALUE_TAGS && LITERAL_IS_SYMBOL[Int(b)]
        return LITERAL_SYMBOL_HASHES[Int(b)]
    elseif b == Serialization.SHORTBACKREF_TAG || b == Serialization.BACKREF_TAG || b == Serialization.LONGBACKREF_TAG
        e = Serialization._getbackref(s, read_backref_id(s, b))
        e isa SymEntry && return e.h
    end
    bad_stream("a name was expected")
    return UInt64(0)
end

@inline function read_backref_id(s::Serializer, b::Int32)::Int
    b == Serialization.SHORTBACKREF_TAG && return Int(read(s.io, UInt16)::UInt16)
    b == Serialization.BACKREF_TAG && return Int(read(s.io, Int32)::Int32)
    return Int(read(s.io, Int64)::Int64)
end

# the hash of a module: the tag `MODULE_TAG` has been read
function read_module_hash(s::Serializer)::UInt64
    next_tag(s) == Serialization.MODULE_TAG || bad_stream("a module was expected")
    b = next_tag(s)
    h = H_MOD
    if b == Serialization.sertag(nothing)
        h = mix(h, UInt64(0))
    elseif b == Serialization.sertag(UInt128)
        v = read(s.io, UInt128)::UInt128
        h = mix(mix(mix(h, UInt64(1)), UInt64(v % UInt64)), UInt64((v >> 64) % UInt64))
    else
        bad_stream("the UUID of a package was expected")
    end
    h = mix(h, read_symbol_hash(s, next_tag(s)))
    while true
        b = next_tag(s)
        b == Serialization.EMPTYTUPLE_TAG && break
        h = mix(h, read_symbol_hash(s, b))
    end
    return h
end

# the hash of the type, when the tag `b` has been read (and the number of its parameters is known from the types that the
# program has: `has_params`)
function read_type_hash(s::Serializer, b::Int32, ::Val{All})::UInt64 where {All}
    if b == 0
        return mix(H_TAG, UInt64(next_tag(s)))
    elseif b >= VALUE_TAGS && TAG_IS_TYPE[Int(b)]
        return mix(H_TAG, UInt64(b))
    elseif b == Serialization.DATATYPE_TAG
        slot = s.counter
        s.counter += 1
        name = read_symbol_hash(s, next_tag(s))
        modh = read_module_hash(s)
        key = mix(mix(H_DT, name), modh)
        h = key
        if has_params(Val{All}(), key)
            np = Int(read(s.io, Int32)::Int32)
            h = mix(h, np)
            for _ in 1:np
                h = mix(h, read_param_hash(s, next_tag(s), Val{All}()))
            end
        end
        Serialization._setbackref!(s, slot, TypeEntry(h))
        return h
    elseif b == Serialization.sertag(Union)
        a = read_type_hash(s, next_tag(s), Val{All}())
        return mix(mix(H_UN, a), read_type_hash(s, next_tag(s), Val{All}()))
    elseif b == Serialization.SHORTBACKREF_TAG || b == Serialization.BACKREF_TAG || b == Serialization.LONGBACKREF_TAG
        e = Serialization._getbackref(s, read_backref_id(s, b))
        e isa TypeEntry && return e.h
    end
    bad_stream("a type was expected")
    return UInt64(0)
end

function is_type_tag(b::Int32)
    return b == 0 || b == Serialization.DATATYPE_TAG || b == Serialization.sertag(Union) || b == Serialization.SHORTBACKREF_TAG || b == Serialization.BACKREF_TAG ||
           b == Serialization.LONGBACKREF_TAG || (b >= VALUE_TAGS && TAG_IS_TYPE[Int(b)])
end

# the hash of a parameter of a type: a type, a number, a symbol, a boolean or a tuple of them
function read_param_hash(s::Serializer, b::Int32, ::Val{All})::UInt64 where {All}
    if b == Serialization.TRUE_TAG
        return mix(H_PARAM, 2)
    elseif b == Serialization.FALSE_TAG
        return mix(H_PARAM, 1)
    elseif b == Serialization.EMPTYTUPLE_TAG
        return mix(mix(H_PARAM, 5), 0)
    elseif b == Serialization.TUPLE_TAG
        n = Int(read(s.io, UInt8)::UInt8)
        h = mix(mix(H_PARAM, 5), n)
        for _ in 1:n
            h = mix(h, read_param_hash(s, next_tag(s), Val{All}()))
        end
        return h
    elseif b >= Serialization.ZERO64_TAG
        return mix(mix(H_INT, 3), Int(b - Serialization.ZERO64_TAG))
    elseif b == Serialization.SHORTINT64_TAG
        return mix(mix(H_INT, 3), Int(read(s.io, Int32)::Int32))
    elseif b == Serialization.sertag(Int64)
        return mix(mix(H_INT, 3), read(s.io, Int64)::Int64)
    elseif b == Serialization.SYMBOL_TAG || b == Serialization.LONGSYMBOL_TAG || (b >= VALUE_TAGS && LITERAL_IS_SYMBOL[Int(b)])
        return mix(mix(H_PARAM, 4), read_symbol_hash(s, b))
    elseif is_type_tag(b)
        if b == Serialization.SHORTBACKREF_TAG || b == Serialization.BACKREF_TAG || b == Serialization.LONGBACKREF_TAG
            e = Serialization._getbackref(s, read_backref_id(s, b))
            e isa SymEntry && return mix(mix(H_PARAM, 4), e.h)
            e isa TypeEntry && return e.h
            bad_stream("a parameter of a type was expected")
        end
        return read_type_hash(s, b, Val{All}())
    end
    bad_stream("a parameter of a type that is not supported")
    return UInt64(0)
end

# the types that the program has, with the hash of the name and module of each (what has parameters follows it in the stream)
function type_keys!(out::Dict{UInt64,Bool}, @nospecialize(T), seen::Set{Any})
    T in seen && return
    push!(seen, T)
    if T isa DataType
        tag = Serialization.sertag(T)
        if !(tag > 0 || T === Tuple)
            out[mix(mix(H_DT, sym_hash(String(nameof(T)))), mod_hash(parentmodule(T)))] = !isempty(T.parameters)
        end
        for p in T.parameters
            (p isa DataType || p isa Union || p isa Tuple) && type_keys!(out, p, seen)
        end
    elseif T isa Union
        type_keys!(out, T.a, seen)
        type_keys!(out, T.b, seen)
    elseif T isa Tuple
        for x in T
            (x isa DataType || x isa Union) && type_keys!(out, x, seen)
        end
    end
    return
end

@generated function has_params(::Val{All}, key::UInt64) where {All}
    keys = Dict{UInt64,Bool}()
    seen = Set{Any}()
    for T in Base.uniontypes(All)
        T isa DataType && type_keys!(keys, T, seen)
    end
    chain = :(unknown_type(key))
    for (k, v) in keys
        chain = :(key == $k ? $v : $chain)
    end
    return chain
end


## values

# `Val{Tgt}`: what is read is of this type (a field of a struct is of the type that it has: the values of the types of `All`
# that are of it are what the reader is made for); `All`: the types that the program has

# the union of the tuples (and arrays, ...) of the types of `All` that fit, as the reader gives them
members_of(All, Tgt) = Type[m for m in Base.uniontypes(All) if readable(m) && m <: Tgt]

function read_string(s::Serializer, n::Int)
    str = Base._string_n(n)
    unsafe_read(s.io, pointer(str), n)
    return str
end

# the elements of an array of booleans are in runs (a byte of the value and the count)
function read_bool_array!(s::Serializer, a::Array{Bool})
    n = length(a)
    i = 1
    while i <= n
        b = read(s.io, UInt8)::UInt8
        v = (b >> 7) != 0
        nxt = i + Int(b & 0x7f)
        while i < nxt
            a[i] = v
            i += 1
        end
    end
    return a
end

@inline deserialize_cycle(s::Serializer, @nospecialize(x)) = (slot = pop!(s.pending_refs); Serialization._setbackref!(s, slot, x); nothing)

# a number (Int) that is read where the stream has an integer: the tag is `b`
function read_int(s::Serializer, b::Int32)::Int
    b >= Serialization.ZERO64_TAG && return Int(b - Serialization.ZERO64_TAG)
    b == Serialization.SHORTINT64_TAG && return Int(read(s.io, Int32)::Int32)
    b == Serialization.sertag(Int64) && return Int(read(s.io, Int64)::Int64)
    b >= Serialization.ZERO32_TAG && return Int(b - Serialization.ZERO32_TAG)
    b == Serialization.sertag(Int32) && return Int(read(s.io, Int32)::Int32)
    bad_stream("the size of an array was expected")
    return 0
end

# the elements of the arrays, tuples and fields that are read are of the types of `All` that fit the type that they have
function read_noted_value(::Val{All}, s::Serializer) where {All}
    return read_tagged(s, next_tag(s), Val{Any}(), Val{All}())
end

@generated function read_tagged(s::Serializer, b::Int32, ::Val{Tgt}, ::Val{All}) where {Tgt,All}
    members = members_of(All, Tgt)
    RT = Union{members...}
    ret(x) = :(return ($x)::$RT)
    body = Expr(:block)
    emit(x) = push!(body.args, x)
    has(T) = T in members
    # (a header, which starts a stream: the value follows)
    emit(:(b == Serialization.HEADER_TAG && (Serialization.readheader(s); return read_tagged(s, next_tag(s), Val{$(QuoteNode(Tgt))}(), Val{$(QuoteNode(All))}()))))
    # values that are a tag
    if has(Bool)
        emit(:(b == Serialization.TRUE_TAG && $(ret(true))))
        emit(:(b == Serialization.FALSE_TAG && $(ret(false))))
    end
    has(Nothing) && emit(:(b == $(Serialization.sertag(nothing)) && $(ret(nothing))))
    has(Tuple{}) && emit(:(b == Serialization.EMPTYTUPLE_TAG && $(ret(())) ))
    # numbers
    if has(Int64)
        emit(:(b >= Serialization.ZERO64_TAG && $(ret(:(Int64(b - Serialization.ZERO64_TAG))))))
        emit(:(b == Serialization.SHORTINT64_TAG && $(ret(:(Int64(read(s.io, Int32)::Int32))))))
    end
    has(Int32) && emit(:(b >= Serialization.ZERO32_TAG && b < Serialization.ZERO64_TAG && $(ret(:(Int32(b - Serialization.ZERO32_TAG))))))
    for T in NUMBER_TYPES
        has(T) && emit(:(b == $(Serialization.sertag(T)) && $(ret(:(read(s.io, $T)::$T)))))
    end
    # strings
    if has(String)
        emit(:(b == Serialization.STRING_TAG && $(ret(:(read_string(s, Int(read(s.io, UInt8)::UInt8))))) ))
        emit(:(b == Serialization.LONGSTRING_TAG && $(ret(:(read_string(s, Int(read(s.io, Int64)::Int64)))))))
        emit(quote
            if b == Serialization.SHARED_REF_TAG
                slot = s.counter
                s.counter += 1
                str = read_tagged(s, next_tag(s), Val{String}(), Val{$(QuoteNode(All))}())::String
                Serialization._setbackref!(s, slot, str)
                return str::$RT
            end
        end)
    end
    # back references: objects that came before
    heap = Type[m for m in members if !(m in NUMBER_TYPES) && m !== Bool && m !== Nothing && m !== Tuple{}]
    if !isempty(heap)
        narrow = :(bad_stream("a back reference to a value that is not of a type that fits"))
        for m in reverse(heap)
            narrow = :(e isa $m ? e : $narrow)
        end
        emit(quote
            if b == Serialization.SHORTBACKREF_TAG || b == Serialization.BACKREF_TAG || b == Serialization.LONGBACKREF_TAG
                e = Serialization._getbackref(s, read_backref_id(s, b))
                return ($narrow)::$RT
            end
        end)
    end
    # tuples: of each length that there are
    tuples = Type[m for m in members if is_tuple_type(m)]
    if !isempty(tuples)
        inner = Expr(:block)
        for L in sort(unique(length(t.parameters) for t in tuples))
            cands = Type[t for t in tuples if length(t.parameters) == L]
            names = [Symbol("e", i) for i in 1:L]
            reads = Expr(:block)
            for i in 1:L
                ti = Union{(t.parameters[i] for t in cands)...}
                push!(reads.args, :($(names[i]) = read_tagged(s, next_tag(s), Val{$(QuoteNode(ti))}(), Val{$(QuoteNode(All))}())))
            end
            push!(inner.args, quote
                if n == $L
                    $reads
                    return $(Expr(:tuple, names...))::$(Union{cands...})
                end
            end)
        end
        emit(quote
            if b == Serialization.TUPLE_TAG
                n = Int(read(s.io, UInt8)::UInt8)
                $inner
            end
        end)
    end
    # arrays
    arrays = Type[m for m in members if is_array_type(m)]
    if !isempty(arrays)
        maxN = maximum(ndims(a) for a in arrays)
        dnames = [Symbol("d", i) for i in 1:maxN]
        reads = Expr(:block)
        push!(reads.args, :(nd = 1))
        for i in 1:maxN
            push!(reads.args, :($(dnames[i]) = 0))
        end
        dimread = Expr(:block)
        for i in 1:maxN
            push!(dimread.args, :(nd >= $i && ($(dnames[i]) = read_int(s, next_tag(s)))))
        end
        push!(reads.args, quote
            if b3 == Serialization.TUPLE_TAG
                nd = Int(read(s.io, UInt8)::UInt8)
                $dimread
            else
                d1 = read_int(s, b3)
            end
        end)
        chain = Expr(:block)
        for A in arrays
            E, N = A.parameters
            eh = type_hash_of(E)
            eh === nothing && continue
            push!(chain.args, :(eh == $(UInt64(eh)) && nd == $N && return read_array(s, Val{$(QuoteNode(A))}(), Val{$(QuoteNode(All))}(), slot, $(dnames[1:N]...))::$RT))
        end
        emit(quote
            if b == Serialization.ARRAY_TAG
                slot = s.counter
                s.counter += 1
                b2 = next_tag(s)
                if is_type_tag(b2)
                    eh = read_type_hash(s, b2, Val{$(QuoteNode(All))}())
                    b3 = next_tag(s)
                else
                    eh = $(UInt64(type_hash_of(UInt8)))
                    b3 = b2
                end
                $reads
                $chain
                unknown_type(eh)
            end
        end)
    end
    # structs: an immutable one is `OBJECT_TAG`, a mutable one (and a `Dict`) `REF_OBJECT_TAG`
    immutables = Type[m for m in members if is_struct_type(m) && !ismutabletype(m)]
    if !isempty(immutables)
        chain = Expr(:block)
        for S in immutables
            push!(chain.args, :(h == $(UInt64(type_hash_of(S))) && return read_struct(s, Val{$(QuoteNode(S))}(), Val{$(QuoteNode(All))}())::$RT))
        end
        emit(quote
            if b == Serialization.OBJECT_TAG
                h = read_type_hash(s, next_tag(s), Val{$(QuoteNode(All))}())
                $chain
                unknown_type(h)
            end
        end)
    end
    mutables = Type[m for m in members if (is_struct_type(m) && ismutabletype(m)) || is_dict_type(m)]
    if !isempty(mutables)
        chain = Expr(:block)
        for S in mutables
            reader = is_dict_type(S) ? :read_dict : :read_mutable
            push!(chain.args, :(h == $(UInt64(type_hash_of(S))) && return $reader(s, Val{$(QuoteNode(S))}(), Val{$(QuoteNode(All))}())::$RT))
        end
        emit(quote
            if b == Serialization.REF_OBJECT_TAG
                slot = s.counter
                s.counter += 1
                push!(s.pending_refs, slot)
                h = read_type_hash(s, next_tag(s), Val{$(QuoteNode(All))}())
                $chain
                unknown_type(h)
            end
        end)
    end
    emit(:(stream_error(b)))
    return body
end

# an array of the type: `slot` is the number of its back reference, `dims` its sizes
@generated function read_array(s::Serializer, ::Val{A}, ::Val{All}, slot::Int, dims::Vararg{Int}) where {A,All}
    E, N = A.parameters
    ndims = length(dims) # (the ones that were read: the type has `N`)
    dd = [:(dims[$i]) for i in 1:N]
    if isbitstype(E) && E !== Bool
        return quote
            a = Array{$E,$N}(undef, $(dd...))
            Serialization._setbackref!(s, slot, a)
            read!(s.io, a)
            return a
        end
    elseif E === Bool
        return quote
            a = Array{Bool,$N}(undef, $(dd...))
            Serialization._setbackref!(s, slot, a)
            length(a) > 0 && read_bool_array!(s, a)
            return a
        end
    end
    return quote
        a = Array{$E,$N}(undef, $(dd...))
        Serialization._setbackref!(s, slot, a)
        for i in eachindex(a)
            b = next_tag(s)
            b == Serialization.UNDEFREF_TAG && continue
            a[i] = read_tagged(s, b, Val{$(QuoteNode(E))}(), Val{$(QuoteNode(All))}())
        end
        return a
    end
end

# an object of an immutable struct: its fields one after the other (the last ones may be undefined, which the type of a struct
# allows only for its tail)
@generated function read_struct(s::Serializer, ::Val{S}, ::Val{All}) where {S,All}
    nf = fieldcount(S)
    nf == 0 && return Expr(:new, S)
    names = [Symbol("f", i) for i in 1:nf]
    body = Expr(:block)
    for i in 1:nf
        ft = fieldtype(S, i)
        push!(body.args, quote
            b = next_tag(s)
            b == Serialization.UNDEFREF_TAG && bad_stream("a field of a struct that is not defined")
            $(names[i]) = read_tagged(s, b, Val{$(QuoteNode(ft))}(), Val{$(QuoteNode(All))}())
        end)
    end
    push!(body.args, Expr(:new, S, names...))
    return body
end

# an object of a mutable struct: made before its fields are read, so that they can refer to it
@generated function read_mutable(s::Serializer, ::Val{S}, ::Val{All}) where {S,All}
    nf = fieldcount(S)
    consts = any(i -> Base.isconst(S, i), 1:nf)
    body = Expr(:block)
    if consts
        # (a field that is `const` can not be set after the object is made: the fields are read first, and the object does not
        # exist for the fields to refer to)
        names = [Symbol("f", i) for i in 1:nf]
        push!(body.args, :(slot = pop!(s.pending_refs)))
        for i in 1:nf
            ft = fieldtype(S, i)
            push!(body.args, quote
                b = next_tag(s)
                b == Serialization.UNDEFREF_TAG && bad_stream("a field of a struct that is not defined")
                $(names[i]) = read_tagged(s, b, Val{$(QuoteNode(ft))}(), Val{$(QuoteNode(All))}())
            end)
        end
        push!(body.args, :(x = $(Expr(:new, S, names...))))
        push!(body.args, :(Serialization._setbackref!(s, slot, x)))
        push!(body.args, :(return x))
        return body
    end
    push!(body.args, :(x = $(Expr(:new, S))))
    push!(body.args, :(deserialize_cycle(s, x)))
    for i in 1:nf
        ft = fieldtype(S, i)
        push!(body.args, quote
            b = next_tag(s)
            b == Serialization.UNDEFREF_TAG || setfield!(x, $i, read_tagged(s, b, Val{$(QuoteNode(ft))}(), Val{$(QuoteNode(All))}()))
        end)
    end
    push!(body.args, :(return x))
    return body
end

@generated function read_dict(s::Serializer, ::Val{D}, ::Val{All}) where {D,All}
    K, V = D.parameters
    return quote
        n = Int(read(s.io, Int32)::Int32)
        d = $D()
        sizehint!(d, n)
        deserialize_cycle(s, d)
        for _ in 1:n
            k = read_tagged(s, next_tag(s), Val{$(QuoteNode(K))}(), Val{$(QuoteNode(All))}())
            v = read_tagged(s, next_tag(s), Val{$(QuoteNode(V))}(), Val{$(QuoteNode(All))}())
            d[k] = v
        end
        return d
    end
end

# `deserialize(s)` is a read over the types that the program has (for Julia's reader the types of the stream are made when
# it runs: here they are looked up in those)
@device_override Serialization.deserialize(s::Serializer) = StaticRuntime.call_over_noted(:deserialize, read_noted_value, s)

# `serialize(io, x)` of a program: the types that it writes are the types that it can read (what the type holds too)
@generated function note_serialized(::Type{T}) where {T}
    body = Expr(:block)
    for U in noted_closure!(Type[], T)
        push!(body.args, :(StaticRuntime.note_type(:deserialize, $(QuoteNode(U)))))
    end
    push!(body.args, nothing)
    return body
end

@device_override function Serialization.serialize(io::IO, x)
    note_serialized(typeof(x))
    ss = Serializer(io)
    Serialization.writeheader(ss)
    Serialization.serialize(ss, x)
end

# `add_deserialize_types!(T...)`: the types, and what they hold
function StaticRuntime.add_deserialize_types!(types::Type...)
    for T in types, U in noted_closure!(Type[], T)
        StaticRuntime.add_noted_types!(:deserialize, U)
    end
    return nothing
end

end

