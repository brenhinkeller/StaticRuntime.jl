# Observables (the package that Makie, and the packages around it, build their updates on) in a program.
#
# The package keeps its listeners as `Pair{Int,Any}`, and what it calls through is written not to be specialized (`@nospecialize`, `f::Any`), which keeps Julia from compiling it for each function and type. The
# compiler finds the functions that such a call can be, and makes the call over them (see "Calls of functions that are not known" in the manual), so most of the package is compiled as it is. What is written again here
# is what that does not reach: the value of an observable that is set (converted to its type), `on`, which does not call the functions of the tools that watch the observables, and `map!` and `onany`, whose callbacks have the
# types of the function, the result and the arguments.

module StaticRuntimeObservablesExt

using StaticRuntime: StaticRuntime, @device_override, note_callback, call_callback, add_callback!
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
    note_callback(value_type(observable), f)
    update && f(observable[])
    return ObserverFunction(f, observable, weak)
end


# The listeners are kept as `Pair{Int,Any}`: they are the functions that are said to be listeners of an observable of a type (`note_callback`), and `notify` calls those of the type of the observable, and no others
# (see "Callbacks" in the manual): a call over all of the functions that the program has is a call of all of them with every value, which none of them is made for.
value_type(::Observable{T}) where {T} = T
value_type(::AbstractObservable) = Any

@device_override function Base.notify(observable::Observable{T}) where {T}
    val = observable[]
    for (_, f) in Observables.listeners(observable)::Vector{Pair{Int,Any}}
        result = call_callback(T, f, val)
        if result isa Observables.Consume && result.x
            return true # (stop calling the listeners if an event got consumed)
        end
    end
    return false
end

# whether a function (a closure) has a `Module` among what it took, in what it took (the closures, tuples and references that it has: three deep)
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

# The listeners of the observables that were made before the program is compiled (in a scene that is a constant) are not said by the code of the program: the observables that `x` refers to are looked at, and the
# listeners of `map` that they have are replaced with the `MapCall`s that `map!` makes.
function StaticRuntime.add_listeners!(@nospecialize(root); budget::Int = 2_000_000)
    seen = Base.IdSet{Any}()
    todo = Any[root]
    while !isempty(todo) && budget > 0
        x = pop!(todo)
        (x isa Type || x isa Module || x isa Symbol || x isa String || x isa Number || x isa Char || x === nothing) && continue
        x in seen && continue
        push!(seen, x)
        budget -= 1
        if x isa Observable
            ls = x.listeners
            # (a listener that has a `Module` is not one that a program can have: a module is a structure of the runtime, and has no copy in the binary, so the listeners that have one, and the observable, would not be in it. They
            # are the ones of the interactions with the mouse and the keyboard (`addmouseevents!`), which a program that has no events does not call: they are taken out)
            filter!(p -> !holds_module(p.second), ls)
            for i in eachindex(ls)
                p = ls[i]
                f = p.second
                if f isa Observables.MapCallback
                    # (what `map` made: the function, the result and the arguments of the type `Any`, as `map!` makes them in a program, with their types)
                    f = MapCall(f.f, f.result, f.args)
                    ls[i] = Pair{Int,Any}(p.first, f)
                elseif f isa Observables.OnAny
                    # (what `onany` made, likewise)
                    f = AnyCall(f.f, f.args)
                    ls[i] = Pair{Int,Any}(p.first, f)
                end
                add_callback!(value_type(x), typeof(f))
            end
        end
        # (the handles that a block keeps to take its listeners out again are of the same kind: they have the functions)
        x isa Vector{ObserverFunction} && filter!(o -> !holds_module(o.f), x)
        if x isa Array || x isa Core.GenericMemory
            isbitstype(eltype(x)) && continue
            for i in eachindex(x)
                isassigned(x, i) && push!(todo, x[i])
            end
        elseif x isa Dict
            for (k, v) in x; push!(todo, k); push!(todo, v); end
        elseif x isa Function || isstructtype(typeof(x))
            T = typeof(x)
            for i in 1:fieldcount(T)
                isdefined(x, i) && push!(todo, getfield(x, i))
            end
        end
    end
    return nothing
end

# `off`, without what is called when a listener is removed (`removehandler_callbacks`, for tools that watch the observables: a list of functions of the type `Function`, which nothing in a program adds to). An overlay
# covers the methods of Base that it fits, so the one for an `ObserverFunction` is here too
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

end # module
