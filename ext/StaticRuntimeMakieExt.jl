# Makie in a program (the latest release only). What Makie writes to keep Julia from
# compiling for each type, or in a way that the types of the values are lost, is written again here with the types known.

module StaticRuntimeMakieExt

using StaticRuntime: @device_override, add_dispatch_candidates!
using Makie: Makie, Scene, SSAO, Attributes

# The finalizer of a `Scene` frees what the screens of a backend hold: there are no screens that the program has not closed
@device_override Base.finalizer(f::Function, scene::Scene) = scene

# The pairs of the attributes: the value is of any type, and `Pair(key, value)` takes the type of the pair from the type of the value
@device_override function Base.iterate(x::Attributes, state...)
    s = iterate(keys(x), state...)
    s === nothing && return nothing
    return (Pair{Symbol,Any}(s[1], x[s[1]]), s[2])
end

# The defaults of the `SSAO` are the attributes of the theme, with values of the types of its fields. The theme for a key may be given as anything (`theme` is inferred as a union with `Nothing`,
# `Observable` and `NamedTuple`), and the call of the constructor with each of them is not one that can be split
@device_override function Makie.SSAO(; radius = nothing, bias = nothing, blur = nothing)
    defaults = Makie.theme(nothing, :SSAO)::Attributes
    _radius = isnothing(radius) ? defaults.radius[]::Float32 : radius
    _bias = isnothing(bias) ? defaults.bias[]::Float32 : bias
    _blur = isnothing(blur) ? defaults.blur[]::Int32 : blur
    return SSAO(_radius, _bias, _blur)
end

# The default gaps of a `GridLayout` are those of the theme: GridLayoutBase calls a function that Makie keeps in a `Ref` (`DEFAULT_COLGAP_GETTER[]()`, set when Makie is loaded), and the call of a function
# that is stored where its type is lost is the call of any function. The functions that are stored are these, with the same result
# (`theme(key; default)` is a union of types, `Nothing`, `Attributes`, `Observable` and an abstract `NamedTuple`, so the theme is read here: what it gives for a key that is in it)
function theme_gap(key::Symbol, default::Float64)
    t = Makie.current_default_theme()
    haskey(t, key) || return default
    return convert(Float64, Makie.to_value(t[key])::Real)
end
@device_override Makie.GridLayoutBase.get_default_colgap()::Float64 = theme_gap(:colgap, Float64(Makie.GridLayoutBase.DEFAULT_COLGAP[]))
@device_override Makie.GridLayoutBase.get_default_rowgap()::Float64 = theme_gap(:rowgap, Float64(Makie.GridLayoutBase.DEFAULT_ROWGAP[]))

# The compute graph. A graph that is made when the program is compiled is embedded in it, and the edges that were resolved then have a `TypedEdge`, with the types of what they hold. What it does not have is the names of the
# outputs: `resolve!` makes the `last` of a callback as `NamedTuple{names}(vals)` with the names read from the nodes, which are values and not types, so the type of `last` (that a callback reads `last.chunk_u8` of) is lost.
# `name_outputs!` makes the outputs of the typed edges a `NamedTuple` (the names are then in the type), and `resolve!` of those is the same with `last` being the outputs.
const CP = Makie.ComputePipeline

"""
    name_outputs!(graph)

Gives the typed edges of the resolved edges of `graph` outputs that have their names in their type (see above). Done once, when the program is compiled, after the graph was resolved.
"""
function name_outputs!(graph::CP.ComputeGraph)
    for node in values(graph.outputs)
        edge = node.parent
        edge isa CP.ComputeEdge && isassigned(edge.typed_edge) || continue
        te = edge.typed_edge[]
        te.outputs isa NamedTuple && continue
        names = ntuple(i -> edge.outputs[i].name, length(edge.outputs))
        edge.typed_edge[] = CP.TypedEdge(te.callback, te.inputs, te.inputs_dirty, NamedTuple{names}(te.outputs), te.output_nodes)
    end
    return graph
end

# (an edge that gives its inputs as its outputs, which a node of another graph is connected with: the method of the package for it, which the one below would be used in place of)
@device_override function CP.resolve!(edge::CP.TypedEdge{IT,OT,typeof(CP.compute_identity)}) where {IT,OT<:NamedTuple}
    for i in eachindex(edge.inputs_dirty)
        edge.output_nodes[i].dirty |= edge.inputs_dirty[i]
    end
    return
end

@device_override @noinline function CP.resolve!(edge::CP.TypedEdge{<:Any,<:NamedTuple})
    if any(edge.inputs_dirty)
        dirty = CP._get_named_change(edge.inputs, edge.inputs_dirty)
        result = edge.callback(map(getindex, edge.inputs), dirty, map(getindex, edge.outputs))
        if result isa Tuple
            length(result) == length(edge.outputs) || CP.throw_length_mismatch(edge, result)
            CP.set_result!(edge, result)
        elseif isnothing(result)
            foreach(x -> x.dirty = false, edge.output_nodes)
        else
            CP.throw_invalid_result(result)
        end
    end
    return
end

# What a function that is given to `map!` gives is of any type where inference does not know it (`lighting_mode` gives the `shading`, which is an `Any`, or a `ShadingAlgorithm`), and the tuple that is made of it is made of
# the runtime (`jl_f_tuple`), and `set_result!` reads it by the index. The outputs of an edge have the types that they had when the graph was resolved, and `last` (what the edge has now) says them: the result is converted to
# each of them, which is what storing it in the `RefValue` does (`nothing` and a `RefValue` are as they are: see `set_result!`).
narrow_result(::Type{T}, x) where {T} = x === nothing ? x : x isa Base.RefValue ? x : convert(T, x)

@device_override function (x::CP.MapFunctionWrapper{true})(inputs, @nospecialize(changed), cached)
    result = x.user_func(values(inputs)...)
    cached isa NamedTuple || return (result,)
    return (narrow_result(fieldtype(typeof(cached), 1), result),)
end

# (the tuple that has the types of the outputs: `Tuple{fieldtypes(...)...}` of the named tuple that `last` is)
@generated output_tuple(::Type{NT}) where {NT<:NamedTuple} = Tuple{fieldtypes(NT)...}

@device_override function (x::CP.MapFunctionWrapper{false})(inputs, @nospecialize(changed), cached)
    result = x.user_func(values(inputs)...)
    (cached isa NamedTuple && result isa Tuple) || return result
    R = output_tuple(typeof(cached))
    result isa R || error("a function of a compute graph gave values that do not have the types of its outputs (", typeof(result), " for ", R, "): the program stops, as the types of the outputs are those of the graph when it was compiled")
    return result::R
end

# The first resolve of an edge makes its `TypedEdge`, with types that are made when it runs (`NamedTuple{names}`, `Base.invokelatest`). The edges of a program are resolved when it is compiled (`name_outputs!` is called after that),
# so that the call is not one that the program makes.
@device_override CP.TypedEdge(edge::CP.ComputeEdge) = error("an edge of a compute graph is resolved for the first time when the program runs: resolve the graph when it is compiled")

# `update!(graph; name = value, ...)` makes a `Pair{Symbol,Any}` of each, which holds a value of any type (its field is an `Any` that anything that makes one stores in), and the values are read from them as an `Any`.
# The keywords are the values with their types, and are set as they are.
@device_override function CP.update!(attr::CP.ComputeGraph; kwargs...)
    return lock(attr.lock) do
        for (key, value) in kwargs
            haskey(attr.inputs, key) || error("Attribute ", key, " not found in ComputeGraph")
            CP._setproperty!(attr, key, value)
        end
        CP.update_observables!(attr)
        return attr
    end
end

# The value of an input is of any type, and `input.value = value` is a call of `setproperty!` that Julia chooses a method of by the type of the value (`Input` has methods for an `Observable` and a `Computed`, which are
# errors), which is a call that is made when the program runs. The field is set here, with what these do for any other type.
@device_override function Base.setindex!(input::CP.Input, @nospecialize(value))
    CP.is_same(input.value, value) && return value
    setfield!(input, :value, value)
    CP.mark_dirty!(input)
    CP.update_observables!(input)
    return value
end

@device_override function CP._setproperty!(attr::CP.ComputeGraph, key::Symbol, @nospecialize(value))
    input = attr.inputs[key]
    CP.is_same(input.value, value) && return value
    CP.mark_dirty!(input)
    setfield!(input, :value, value)
    return value
end

# The observable of a node of the graph is made when it is first asked for, of the type of the value that the node has then (`Observable{eltype(val.value)}`): a type that is made when the program runs.
# The observables of a program are the ones that were asked for when it was compiled (`get_observable!(graph, name)`, or `on(f, graph[name])`), and what is asked for later is one of these.
@device_override CP.get_observable!(attr::CP.ComputeGraph, key::Symbol; use_deepcopy = true) = attr.observables[key]

# The values of the attributes are of any type: these are the ones that they have in the theme (the colors and vectors of the lights, the nested `Attributes`, the size)
function __init__()
    add_dispatch_candidates!(Attributes, Makie.RGBf, Makie.Vec3f, Tuple{Int,Int})
    return nothing
end

end # module
