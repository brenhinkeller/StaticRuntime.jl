# Observables (the package that Makie, and the packages around it, build their updates on) in a program.
#
# The package keeps its listeners as `Pair{Int,Any}`, and what it calls through is written not to be specialized
# (`@nospecialize`, `f::Any`), which keeps Julia from compiling it for each function and type. The compiler finds the
# functions that such a call can be, and makes the call over them (see "Calls of functions that are not known" in the
# manual), so most of the package is compiled as it is. What is written again here is what that does not reach: the
# value of an observable that is set (converted to its type), `on`, which does not call the functions of the tools that
# watch the observables, and `map!` and `onany`, whose callbacks have the types of the function, the result and the
# arguments.

module StaticRuntimeObservablesExt

using StaticRuntime: StaticRuntime, @device_override, note_callback, call_callback
using Observables: Observables, Observable, AbstractObservable, ObserverFunction, to_value, appendinputs!

# `observable[] = val`: the value is converted to the type of the observable (the field is of the type `T`), and the
# listeners are called
@device_override function Base.setindex!(observable::Observable{T}, val) where {T}
    if observable.ignore_equal_values
        isequal(observable.val, val) && return
    end
    observable.val = convert(T, val)
    return notify(observable)
end

# `on`, without what is called when a listener is added (`addhandler_callbacks`, which is for tools that watch the
# observables)
@device_override function Observables.on(f, observable::AbstractObservable; weak::Bool = false, priority::Int = 0, update::Bool = false)::ObserverFunction
    Observables.register_callback(observable, priority, f)
    note_callback(value_type(observable), f)
    update && f(observable[])
    return ObserverFunction(f, observable, weak)
end


# The listeners are kept as `Pair{Int,Any}`: they are the functions that are said to be listeners of an observable of a
# type (`note_callback`), and `notify` calls those of the type of the observable, and no others (see "Callbacks" in the
# manual): a call over all of the functions that the program has is a call of all of them with every value, which none
# of them is made for.
value_type(::Observable{T}) where {T} = T
value_type(::AbstractObservable) = Any

# The listeners of the observables that the program has as constants (of a scene that was made before it is compiled)
# are known objects: the compilation finds them in the constants (`held_listeners`, see "Listeners" in
# src/inference/closures.jl), and so are the observables. The code that updates an observable that is a constant, `obs[]
# = v` and `notify(obs)`, is made for it (see src/inference/object_calls.jl: `setindex_key` and `notify_key` below,
# compiled for the key of the observable), with the listeners that it has: `f` is compared with each (`===`), which is
# called by code that is made for it (`call_object`), so that what it holds (the observables of an `onany`, the result
# of a `map`) are constants of that code, and what it reads of them and stores in them is of those, and not of all the
# observables of their types. For an observable that is not known, `f` is compared with all the listeners of the
# constants that are called with a value of its type. A listener that the program makes is called as before, over the
# types that it says (`note_callback`).
StaticRuntime.keyed_method(::typeof(Base.setindex!), ::Observable) = setindex_key
StaticRuntime.keyed_method(::typeof(Base.notify), ::Observable) = notify_key

# (not those that hold a module, the ones of the mouse and the keyboard, which a program that has no events does not
# call, and whose module is not in the binary; nor those that are values of bits, which hold no objects, and are called
# by their type)
listener_functions(o::Observable) = Tuple(p.second for p in o.listeners if !holds_module(p.second) && !StaticRuntime.keyless(p.second))
StaticRuntime.listener_holder(::Type{<:Observable}) = true
StaticRuntime.held_listeners(o::Observable) =
    (value_type(o), listener_functions(o), Tuple(unique!(Any[typeof(p.second) for p in o.listeners if StaticRuntime.keyless(p.second)])))

function setindex_key(k::StaticRuntime.ObjectKey, val)
    observable = StaticRuntime.object_for(k)
    if observable.ignore_equal_values
        isequal(observable.val, val) && return
    end
    observable.val = convert(value_type(observable), val)
    return notify_key(k)
end

function notify_key(k::StaticRuntime.ObjectKey)
    observable = StaticRuntime.object_for(k)
    return notify_listeners(observable, getfield(observable, :val), something(StaticRuntime.known_object_keys(listener_functions, observable), ()))
end

@device_override function Base.notify(observable::Observable{T}) where {T}
    # (where the type of the value is not known, as for an `Observable` of an abstract type, all those of the constants)
    keys = something(StaticRuntime.known_object_keys(StaticRuntime.compared_listeners, T), StaticRuntime.known_object_keys(StaticRuntime.all_compared_listeners, nothing), ())
    return notify_listeners(observable, observable[], keys)
end

# Each listener: compared with each of the ones that are known, in one method (`f` is of the type `Any`: what is called
# is decided by `===`, and not by its type); any other is of a type that the program said (`note_callback`)
@generated function notify_listeners(observable::Observable{T}, val, keys::K) where {T,K<:Tuple}
    call = :(call_callback(T, f, val))
    for i in fieldcount(K):-1:1
        call = :(f === StaticRuntime.object_for(keys[$i]) ? call_object(keys[$i], val) : $call)
    end
    return quote
        for (_, f) in Observables.listeners(observable)::Vector{Pair{Int,Any}}
            result = $call
            if result isa Observables.Consume && result.x
                return true # (stop calling the listeners if an event got consumed)
            end
        end
        return false
    end
end

# (the code of the listener, made for it: what it holds is constants of it, the fields of a `MapCallback` and an `OnAny`
# of the package too, which are of the type `Any`. The values of its arguments are read from them with `getfield`, which
# is of each of them, where `to_value(obs)` would be a call that is given the observable, which Julia does not propagate
# a mutable constant into)
function call_object(k::StaticRuntime.ObjectKey, val)
    g = StaticRuntime.object_for(k)
    if g isa AnyCall || g isa MapCall || g isa Observables.OnAny || g isa Observables.MapCallback
        # (the keys of the arguments, here where they are constants)
        keys = StaticRuntime.known_object_keys(identity, g.args)
        result = keys === nothing ? g.f(map(to_value, g.args)...) : call_with_keys(g.f, keys)
        (g isa AnyCall || g isa Observables.OnAny) && return result
        g.result[] = result
        return nothing
    else
        return g(val)
    end
end

# (`f(key_value(k1), key_value(k2), ...)`: a call, and not a splat of a tuple of what they are, which is a call of
# `Core._apply_iterate` where an element is of a union)
@generated function call_with_keys(f, keys::K) where {K<:Tuple}
    return Expr(:call, :f, (:(key_value(keys[$i])) for i in 1:fieldcount(K))...)
end
key_value(k::StaticRuntime.ObjectKey) = (x = StaticRuntime.object_for(k); x isa Observable ? getfield(x, :val) : to_value(x))

# whether a function (a closure) has a `Module` among what it took, in what it took (the closures, tuples and references
# that it has: three deep)
function holds_module(@nospecialize(f), depth::Int = 3)
    f isa Module && return true
    depth == 0 && return false
    T = typeof(f)
    (f isa Function || f isa Tuple || f isa Base.RefValue) || return false
    for i in 1:fieldcount(T)
        isdefined(f, i) || continue
        holds_module(getfield(f, i), depth - 1) && return true
    end
    return false
end

# `off`, without what is called when a listener is removed (`removehandler_callbacks`, for tools that watch the
# observables: a list of functions of the type `Function`, which nothing in a program adds to). An overlay covers the
# methods of Base that it fits, so the one for an `ObserverFunction` is here too
@device_override function Observables.off(observable::AbstractObservable, f)
    callbacks = Observables.listeners(observable)
    for (i, (_, f2)) in enumerate(callbacks)
        if f === f2
            deleteat!(callbacks, i)
            return true
        end
    end
    return false
end
@device_override Observables.off(observable::AbstractObservable, obsfunc::ObserverFunction) = Observables.off(observable, obsfunc.f)

# What a `map!`ed observable and an `onany` call when an observable changes, with the types of the function, the result
# and the arguments (the callbacks of the package have them as `Any`)
struct MapCall{F,R,A<:Tuple} <: Function
    f::F
    result::R
    args::A
end
function (c::MapCall)(_)
    c.result[] = c.f(map(to_value, c.args)...)
    return
end

struct AnyCall{F,A<:Tuple} <: Function
    f::F
    args::A
end
function (c::AnyCall)(_)
    return c.f(map(to_value, c.args)...)
end

@device_override function Base.map!(f, result::AbstractObservable, os...; update::Bool = true, priority::Int = 0)
    callback = MapCall(f, result, os)
    obsfuncs = ObserverFunction[]
    for o in os
        if o isa AbstractObservable
            push!(obsfuncs, Observables.on(callback, o; priority = priority))
        end
    end
    appendinputs!(result, obsfuncs)
    update && callback(nothing)
    return result
end

@device_override function Observables.onany(f, args...; weak::Bool = false, priority::Int = 0, update::Bool = false)
    callback = AnyCall(f, args)
    obsfuncs = ObserverFunction[]
    for observable in args
        if observable isa AbstractObservable
            push!(obsfuncs, Observables.on(callback, observable; weak = weak, priority = priority))
        end
    end
    update && callback(nothing)
    return obsfuncs
end

end # module
