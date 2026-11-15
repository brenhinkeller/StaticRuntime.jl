# Observables (the package that Makie, and the packages around it, build their updates on) in a program.
#
# The package keeps its listeners as `Pair{Int,Any}`, and what it calls through is written not to be specialized (`@nospecialize`, `f::Any`), which keeps Julia from compiling it for each function and type. The
# compiler finds the functions that such a call can be, and makes the call over them (see "Calls of functions that are not known" in the manual), so most of the package is compiled as it is. What is written again here
# is what that does not reach: the value of an observable that is set (converted to its type), `on`, which does not call the functions of the tools that watch the observables, and `map!` and `onany`, whose callbacks have the
# types of the function, the result and the arguments.

module StaticRuntimeObservablesExt

using StaticRuntime: @device_override, add_dispatch_candidates!
using Observables: Observables, Observable, AbstractObservable, ObserverFunction, to_value, appendinputs!

# `observable[] = val`: the value is converted to the type of the observable (the field is of the type `T`), and the listeners are called
@device_override function Base.setindex!(observable::Observable{T}, val) where {T}
    if observable.ignore_equal_values
        isequal(observable.val, val) && return
    end
    observable.val = convert(T, val)
    return notify(observable)
end

# `on`, without what is called when a listener is added (`addhandler_callbacks`, which is for tools that watch the observables)
@device_override function Observables.on(f, observable::AbstractObservable; weak::Bool = false, priority::Int = 0, update::Bool = false)::ObserverFunction
    Observables.register_callback(observable, priority, f)
    update && f(observable[])
    return ObserverFunction(f, observable, weak)
end


# What a `map!`ed observable and an `onany` call when an observable changes, with the types of the function, the result and the arguments (the callbacks of the package have them as `Any`)
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

# A value of the type `Any` (what a `Dict{Symbol,Any}` of attributes holds) is an `Observable{Any}` when the package is used for that: a call on it is made over this type too
function __init__()
    add_dispatch_candidates!(Observable{Any})
end

end # module
